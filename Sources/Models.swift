import Darwin
import Foundation

enum LaunchTaskScope: String, Hashable, Sendable {
    case userAgent = "当前用户"
    case localAgent = "本机用户"
    case localDaemon = "系统服务"
    case systemAgent = "macOS 用户服务"
    case systemDaemon = "macOS 系统服务"

    var isDaemon: Bool {
        self == .localDaemon || self == .systemDaemon
    }

    var isUserManaged: Bool {
        self == .userAgent
    }
}

enum DetectionConfidence: String, Hashable, Sendable {
    case direct = "直接调用"
    case commandString = "命令字符串"
}

struct RunningCaffeinate: Identifiable, Hashable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let user: String
    let elapsed: String
    let command: String

    var id: Int32 { pid }

    var isOwnedByCurrentUser: Bool {
        uid == UInt32(getuid())
    }

    var redactedCommand: String {
        CommandRedactor.redact(command)
    }

    var modeLabels: [String] {
        CaffeinateArguments.modeLabels(from: command)
    }

    var modeSummary: String {
        let labels = modeLabels
        return labels.isEmpty ? "防止空闲休眠" : labels.joined(separator: " · ")
    }
}

struct CaffeinateLaunchTask: Identifiable, Hashable, Sendable {
    let label: String
    let displayName: String
    let plistPath: String
    let scope: LaunchTaskScope
    let confidence: DetectionConfidence
    let invocation: String
    let schedule: String
    let runAtLoad: Bool
    let isLoaded: Bool
    let isRunning: Bool
    let isDisabled: Bool
    let lastExitCode: Int?

    var id: String { plistPath }

    var redactedInvocation: String {
        CommandRedactor.redact(invocation)
    }

    var canManage: Bool {
        scope.isUserManaged
    }

    var stateLabel: String {
        if isDisabled { return "已停用" }
        if isRunning { return "运行中" }
        if isLoaded { return "等待触发" }
        return "未加载"
    }
}

struct PowerScheduleSnapshot: Sendable {
    let repeatingEvents: [String]
    let systemEvents: [String]
    let rawOutput: String
}

struct MonitorSnapshot: Sendable {
    let processes: [RunningCaffeinate]
    let tasks: [CaffeinateLaunchTask]
    let powerSchedule: PowerScheduleSnapshot
    let errors: [String]
    let capturedAt: Date
}

struct ActionOutcome: Sendable {
    let isSuccess: Bool
    let message: String
}

enum MonitorAction: Identifiable, Sendable {
    case stopProcess(RunningCaffeinate)
    case runTask(CaffeinateLaunchTask)
    case disableTask(CaffeinateLaunchTask)
    case enableTask(CaffeinateLaunchTask)
    case trashTask(CaffeinateLaunchTask)

    var id: String {
        switch self {
        case .stopProcess(let process):
            return "stop-\(process.pid)"
        case .runTask(let task):
            return "run-\(task.id)"
        case .disableTask(let task):
            return "disable-\(task.id)"
        case .enableTask(let task):
            return "enable-\(task.id)"
        case .trashTask(let task):
            return "trash-\(task.id)"
        }
    }

    var title: String {
        switch self {
        case .stopProcess:
            return "停止这个防休眠进程？"
        case .runTask(let task):
            return "立即运行“\(task.displayName)”？"
        case .disableTask(let task):
            return "停用“\(task.displayName)”？"
        case .enableTask(let task):
            return "重新启用“\(task.displayName)”？"
        case .trashTask:
            return "将这个任务移到废纸篓？"
        }
    }

    var message: String {
        switch self {
        case .stopProcess(let process):
            return "将结束 PID \(process.pid) 的 caffeinate 并释放防休眠状态。它包裹的实际工作进程可能仍会继续；定时配置不会被删除。"
        case .runTask(let task):
            return "launchd 会立即触发 \(task.label)。这与等待下一次计划时间效果相同。"
        case .disableTask:
            return "任务将不再自动运行；plist、脚本和历史简报都会保留，之后可在这里重新启用。"
        case .enableTask(let task):
            return task.runAtLoad
                ? "启用后会重新加载任务。由于它设置了 RunAtLoad，可能会立即执行一次。"
                : "启用后会重新加载任务，并等待下一次计划时间。"
        case .trashTask(let task):
            return "将先停用任务，再把以下配置移到废纸篓：\n\(task.plistPath)\n脚本、历史报告和自动唤醒计划不会被删除。"
        }
    }

    var confirmLabel: String {
        switch self {
        case .stopProcess:
            return "停止防休眠"
        case .runTask:
            return "立即运行"
        case .disableTask:
            return "停用任务"
        case .enableTask:
            return "启用任务"
        case .trashTask:
            return "移到废纸篓"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .stopProcess, .disableTask, .trashTask:
            return true
        case .runTask, .enableTask:
            return false
        }
    }
}

enum CaffeinateArguments {
    static func modeLabels(from command: String) -> [String] {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return [] }

        var labels: [String] = []
        var index = 1

        while index < tokens.count {
            let token = tokens[index]
            guard token.hasPrefix("-"), !token.hasPrefix("--") else { break }

            if token == "-t", index + 1 < tokens.count {
                labels.append("定时 \(tokens[index + 1]) 秒")
                index += 2
                continue
            }
            if token == "-w", index + 1 < tokens.count {
                labels.append("等待 PID \(tokens[index + 1])")
                index += 2
                continue
            }

            for flag in token.dropFirst() {
                let label: String?
                switch flag {
                case "i": label = "防止系统空闲休眠"
                case "d": label = "防止屏幕休眠"
                case "m": label = "防止磁盘休眠"
                case "s": label = "接电时防止系统休眠"
                case "u": label = "模拟用户活跃"
                default: label = nil
                }
                if let label, !labels.contains(label) {
                    labels.append(label)
                }
            }
            index += 1
        }

        return labels
    }
}

enum CommandRedactor {
    static func redact(_ command: String) -> String {
        var result = command
        let replacementRules: [(pattern: String, template: String)] = [
            (
                #"(?i)(--[a-z0-9_-]*(?:api[-_]?key|token|password|passwd|secret|authorization)[a-z0-9_-]*(?:=|\s+))([^\s]+)"#,
                "$1••••"
            ),
            (
                #"(?i)(^|\s)((?:[A-Z][A-Z0-9_]*_)?(?:API_KEY|ACCESS_TOKEN|AUTH_TOKEN|TOKEN|PASSWORD|PASSWD|CLIENT_SECRET|SECRET|AUTHORIZATION)=)([^\s]+)"#,
                "$1$2••••"
            ),
            (
                #"(?i)([?&](?:api[-_]?key|access[-_]?token|auth[-_]?token|token|password|passwd|client[-_]?secret|secret|authorization)=)([^&#\s]+)"#,
                "$1••••"
            ),
            (
                #"(?i)(\bBearer\s+)([A-Za-z0-9._~+/\-=]+)"#,
                "$1••••"
            )
        ]

        for rule in replacementRules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rule.template
            )
        }

        if let userInfoRegex = try? NSRegularExpression(
            pattern: #"(?i)(://[^/\s:@]+:)([^@/\s]+)(@)"#
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = userInfoRegex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1••••$3"
            )
        }
        return result
    }
}
