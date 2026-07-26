import Darwin
import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}

enum SystemScanner {
    private struct LaunchDirectory {
        let url: URL
        let scope: LaunchTaskScope
    }

    static func capture() -> MonitorSnapshot {
        var errors: [String] = []
        var processes: [RunningCaffeinate] = []
        var tasks: [CaffeinateLaunchTask] = []
        var powerSchedule = PowerScheduleSnapshot(
            repeatingEvents: [],
            systemEvents: [],
            rawOutput: ""
        )

        do {
            processes = try scanRunningCaffeinate()
        } catch {
            errors.append("无法读取正在运行的进程：\(error.localizedDescription)")
        }

        do {
            tasks = try scanLaunchTasks()
        } catch {
            errors.append("无法读取 launchd 配置：\(error.localizedDescription)")
        }

        do {
            powerSchedule = try scanPowerSchedule()
        } catch {
            errors.append("无法读取自动唤醒计划：\(error.localizedDescription)")
        }

        return MonitorSnapshot(
            processes: processes,
            tasks: tasks,
            powerSchedule: powerSchedule,
            errors: errors,
            capturedAt: Date()
        )
    }

    static func scanRunningCaffeinate() throws -> [RunningCaffeinate] {
        let result = try ProcessRunner.run(
            "/bin/ps",
            ["-axo", "pid=,ppid=,uid=,etime=,command="]
        )
        guard result.status == 0 else {
            throw scannerError(result.standardError, fallback: "ps 返回 \(result.status)")
        }

        let pattern = #"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)$"#
        let regex = try NSRegularExpression(pattern: pattern)

        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> RunningCaffeinate? in
                let line = String(rawLine)
                let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
                guard
                    let match = regex.firstMatch(in: line, range: fullRange),
                    let pidRange = Range(match.range(at: 1), in: line),
                    let parentRange = Range(match.range(at: 2), in: line),
                    let uidRange = Range(match.range(at: 3), in: line),
                    let elapsedRange = Range(match.range(at: 4), in: line),
                    let commandRange = Range(match.range(at: 5), in: line),
                    let pid = Int32(line[pidRange]),
                    let parentPID = Int32(line[parentRange]),
                    let uid = UInt32(line[uidRange])
                else {
                    return nil
                }

                let command = String(line[commandRange])
                guard isCaffeinateExecutable(command) else { return nil }

                return RunningCaffeinate(
                    pid: pid,
                    parentPID: parentPID,
                    uid: uid,
                    user: userName(for: uid),
                    elapsed: String(line[elapsedRange]),
                    command: command
                )
            }
            .sorted { $0.pid < $1.pid }
    }

    static func scanLaunchTasks() throws -> [CaffeinateLaunchTask] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [
            LaunchDirectory(
                url: home.appendingPathComponent("Library/LaunchAgents"),
                scope: .userAgent
            ),
            LaunchDirectory(
                url: URL(fileURLWithPath: "/Library/LaunchAgents"),
                scope: .localAgent
            ),
            LaunchDirectory(
                url: URL(fileURLWithPath: "/Library/LaunchDaemons"),
                scope: .localDaemon
            ),
            LaunchDirectory(
                url: URL(fileURLWithPath: "/System/Library/LaunchAgents"),
                scope: .systemAgent
            ),
            LaunchDirectory(
                url: URL(fileURLWithPath: "/System/Library/LaunchDaemons"),
                scope: .systemDaemon
            )
        ]

        var tasks: [CaffeinateLaunchTask] = []

        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files where file.pathExtension == "plist" {
                guard
                    let data = try? Data(contentsOf: file),
                    let propertyList = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                    ),
                    let dictionary = propertyList as? [String: Any],
                    let task = parseLaunchTask(
                        dictionary: dictionary,
                        file: file,
                        scope: directory.scope
                    )
                else {
                    continue
                }
                tasks.append(task)
            }
        }

        return tasks.sorted {
            if $0.scope == $1.scope {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return scopePriority($0.scope) < scopePriority($1.scope)
        }
    }

    static func scanPowerSchedule() throws -> PowerScheduleSnapshot {
        let result = try ProcessRunner.run("/usr/bin/pmset", ["-g", "sched"])
        guard result.status == 0 else {
            throw scannerError(result.standardError, fallback: "pmset 返回 \(result.status)")
        }

        enum Section {
            case none
            case repeating
            case scheduled
        }

        var section = Section.none
        var repeating: [String] = []
        var scheduled: [String] = []

        for rawLine in result.standardOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Repeating power events:" {
                section = .repeating
                continue
            }
            if line == "Scheduled power events:" {
                section = .scheduled
                continue
            }

            switch section {
            case .repeating:
                repeating.append(localizePowerEvent(line))
            case .scheduled:
                scheduled.append(localizePowerEvent(line))
            case .none:
                continue
            }
        }

        return PowerScheduleSnapshot(
            repeatingEvents: repeating,
            systemEvents: scheduled,
            rawOutput: result.standardOutput
        )
    }

    private static func parseLaunchTask(
        dictionary: [String: Any],
        file: URL,
        scope: LaunchTaskScope
    ) -> CaffeinateLaunchTask? {
        let program = dictionary["Program"] as? String
        let arguments = dictionary["ProgramArguments"] as? [String] ?? []
        let directExecutable = program ?? arguments.first ?? ""
        let direct = URL(fileURLWithPath: directExecutable).lastPathComponent == "caffeinate"

        let searchableStrings = ([program].compactMap { $0 } + arguments)
        let containsCaffeinate = searchableStrings.contains { value in
            value.range(
                of: #"(^|[/\s])caffeinate(?:\s|$)"#,
                options: .regularExpression
            ) != nil
        }

        guard direct || containsCaffeinate else { return nil }

        let label = (dictionary["Label"] as? String)
            ?? file.deletingPathExtension().lastPathComponent
        let domain = scope.isDaemon ? "system" : "gui/\(getuid())"
        let serviceResult = try? ProcessRunner.run(
            "/bin/launchctl",
            ["print", "\(domain)/\(label)"]
        )
        let disabledResult = try? ProcessRunner.run(
            "/bin/launchctl",
            ["print-disabled", domain]
        )

        let loaded = serviceResult?.status == 0
        let serviceOutput = serviceResult?.standardOutput ?? ""
        let running = serviceOutput.range(
            of: #"state\s*=\s*running"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let disabledNeedle = "\"\(label)\" => true"
        let disabled = disabledResult?.standardOutput.contains(disabledNeedle) == true
        let lastExitCode = firstInteger(
            matching: #"last exit code\s*=\s*(-?\d+)"#,
            in: serviceOutput
        )

        let invocation: String
        if !arguments.isEmpty {
            invocation = arguments.joined(separator: " ")
        } else {
            invocation = program ?? "(未提供命令)"
        }

        return CaffeinateLaunchTask(
            label: label,
            displayName: displayName(for: label),
            plistPath: file.path,
            scope: scope,
            confidence: direct ? .direct : .commandString,
            invocation: invocation,
            schedule: formatSchedule(dictionary),
            runAtLoad: boolValue(dictionary["RunAtLoad"]),
            isLoaded: loaded,
            isRunning: running,
            isDisabled: disabled,
            lastExitCode: lastExitCode
        )
    }

    private static func isCaffeinateExecutable(_ command: String) -> Bool {
        guard let executable = command.split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        return URL(fileURLWithPath: String(executable)).lastPathComponent == "caffeinate"
    }

    private static func userName(for uid: UInt32) -> String {
        guard let record = getpwuid(uid_t(uid)) else { return "UID \(uid)" }
        return String(cString: record.pointee.pw_name)
    }

    private static func displayName(for label: String) -> String {
        if label.hasSuffix(".hackernews-yesterday-digest")
            || label == "hackernews-yesterday-digest" {
            return "Hacker News 昨日简报"
        }
        let component = label.split(separator: ".").last.map(String.init) ?? label
        return component
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func formatSchedule(_ dictionary: [String: Any]) -> String {
        var descriptions: [String] = []

        if let intervals = dictionary["StartCalendarInterval"] as? [[String: Any]] {
            descriptions.append(contentsOf: intervals.compactMap(formatCalendarInterval))
        } else if let interval = dictionary["StartCalendarInterval"] as? [String: Any],
                  let description = formatCalendarInterval(interval) {
            descriptions.append(description)
        }

        if let seconds = integerValue(dictionary["StartInterval"]), seconds > 0 {
            if seconds % 3600 == 0 {
                descriptions.append("每 \(seconds / 3600) 小时")
            } else if seconds % 60 == 0 {
                descriptions.append("每 \(seconds / 60) 分钟")
            } else {
                descriptions.append("每 \(seconds) 秒")
            }
        }

        if boolValue(dictionary["RunAtLoad"]) {
            descriptions.append("登录或加载时")
        }
        if dictionary["KeepAlive"] != nil {
            descriptions.append("按需保持运行")
        }

        let unique = descriptions.reduce(into: [String]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }
        return unique.isEmpty ? "未声明固定时间" : unique.joined(separator: "、")
    }

    private static func formatCalendarInterval(_ interval: [String: Any]) -> String? {
        let hour = integerValue(interval["Hour"])
        let minute = integerValue(interval["Minute"]) ?? 0
        let weekday = integerValue(interval["Weekday"])
        let day = integerValue(interval["Day"])
        let month = integerValue(interval["Month"])

        var prefix = "每天"
        if let weekday {
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let normalized = weekday == 7 ? 0 : weekday
            if names.indices.contains(normalized) {
                prefix = "周\(names[normalized])"
            }
        } else if let day, let month {
            prefix = "\(month) 月 \(day) 日"
        } else if let day {
            prefix = "每月 \(day) 日"
        }

        if let hour {
            return String(format: "%@ %02d:%02d", prefix, hour, minute)
        }
        return prefix == "每天" ? nil : prefix
    }

    private static func localizePowerEvent(_ raw: String) -> String {
        var result = raw
        let replacements = [
            ("wakepoweron", "唤醒或开机"),
            ("wakeorpoweron", "唤醒或开机"),
            ("wake", "唤醒"),
            ("poweron", "开机"),
            ("sleep", "睡眠"),
            ("shutdown", "关机"),
            (" at ", "，时间 "),
            (" every day", "，每天")
        ]
        for (source, target) in replacements {
            result = result.replacingOccurrences(of: source, with: target)
        }
        return result
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func firstInteger(matching pattern: String, in text: String) -> Int? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
    }

    private static func scopePriority(_ scope: LaunchTaskScope) -> Int {
        switch scope {
        case .userAgent: return 0
        case .localAgent: return 1
        case .localDaemon: return 2
        case .systemAgent: return 3
        case .systemDaemon: return 4
        }
    }

    private static func scannerError(_ detail: String, fallback: String) -> NSError {
        let message = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return NSError(
            domain: "CaffeinateMonitor.Scanner",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message]
        )
    }
}
