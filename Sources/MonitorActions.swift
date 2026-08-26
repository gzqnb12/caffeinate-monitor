import AppKit
import Darwin
import Foundation

enum MonitorActionError: LocalizedError {
    case permissionDenied
    case processChanged
    case invalidTaskPath
    case commandFailed(String)
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "当前用户没有权限执行这个操作。"
        case .processChanged:
            return "这个进程已经结束或 PID 已被其他进程使用，未执行操作。"
        case .invalidTaskPath:
            return "出于安全考虑，只能管理当前用户 LaunchAgents 目录内的任务。"
        case .commandFailed(let message):
            return message
        case .missingConfiguration:
            return "配置文件已经不存在。"
        }
    }
}

enum MonitorActions {
    static func perform(_ action: MonitorAction) -> ActionOutcome {
        do {
            let message: String
            switch action {
            case .stopProcess(let process):
                try stopProcess(process)
                message = "已停止 PID \(process.pid) 的防休眠进程。"
            case .runTask(let task):
                try runTask(task)
                message = "已触发“\(task.displayName)”。"
            case .disableTask(let task):
                try disableTask(task)
                message = "已停用“\(task.displayName)”，配置文件仍然保留。"
            case .enableTask(let task):
                try enableTask(task)
                message = "已启用“\(task.displayName)”。"
            case .trashTask(let task):
                try trashTask(task)
                message = "已停用任务并将配置文件移到废纸篓。"
            }
            return ActionOutcome(isSuccess: true, message: message)
        } catch {
            return ActionOutcome(isSuccess: false, message: error.localizedDescription)
        }
    }

    private static func stopProcess(_ target: RunningCaffeinate) throws {
        guard target.isOwnedByCurrentUser else {
            throw MonitorActionError.permissionDenied
        }

        let current = try SystemScanner.scanRunningCaffeinate()
        guard
            let verified = current.first(where: { $0.pid == target.pid }),
            verified.parentPID == target.parentPID,
            verified.uid == target.uid,
            verified.command == target.command
        else {
            throw MonitorActionError.processChanged
        }

        guard Darwin.kill(target.pid, SIGTERM) == 0 else {
            if errno == ESRCH { throw MonitorActionError.processChanged }
            throw MonitorActionError.commandFailed(
                String(cString: strerror(errno))
            )
        }
    }

    private static func runTask(_ task: CaffeinateLaunchTask) throws {
        try validateUserTask(task)
        let domain = "gui/\(getuid())/\(task.label)"
        let result = try ProcessRunner.run(
            "/bin/launchctl",
            ["kickstart", "-k", domain]
        )
        try requireSuccess(result, action: "立即运行失败")
    }

    private static func disableTask(_ task: CaffeinateLaunchTask) throws {
        try validateUserTask(task)
        let baseDomain = "gui/\(getuid())"
        let serviceDomain = "\(baseDomain)/\(task.label)"

        let disableResult = try ProcessRunner.run(
            "/bin/launchctl",
            ["disable", serviceDomain]
        )
        if disableResult.status != 0 && !isDisabled(task.label, in: baseDomain) {
            try requireSuccess(disableResult, action: "停用任务失败")
        }

        // `disable` persists the desired state; an unloaded service is already
        // fully stopped. This also makes the operation safe to repeat.
        guard isLoaded(serviceDomain) else { return }

        let bootoutResult = try ProcessRunner.run(
            "/bin/launchctl",
            ["bootout", serviceDomain]
        )

        // On recent macOS versions launchctl can report EIO even though the
        // service was removed successfully. Judge success by the final state.
        if waitUntilUnloaded(serviceDomain) { return }

        // Fall back to the plist form for launchd versions that do not accept
        // the service target in this situation.
        let pathBootoutResult = try ProcessRunner.run(
            "/bin/launchctl",
            ["bootout", baseDomain, task.plistPath]
        )
        if waitUntilUnloaded(serviceDomain) { return }

        if pathBootoutResult.status != 0 {
            try requireSuccess(pathBootoutResult, action: "卸载任务失败")
        }
        try requireSuccess(bootoutResult, action: "卸载任务失败")
    }

    private static func enableTask(_ task: CaffeinateLaunchTask) throws {
        try validateUserTask(task)
        guard FileManager.default.fileExists(atPath: task.plistPath) else {
            throw MonitorActionError.missingConfiguration
        }

        let baseDomain = "gui/\(getuid())"
        let serviceDomain = "\(baseDomain)/\(task.label)"
        let enableResult = try ProcessRunner.run(
            "/bin/launchctl",
            ["enable", serviceDomain]
        )
        if enableResult.status != 0 && isDisabled(task.label, in: baseDomain) {
            try requireSuccess(enableResult, action: "启用任务失败")
        }

        if !isLoaded(serviceDomain) {
            let bootstrapResult = try ProcessRunner.run(
                "/bin/launchctl",
                ["bootstrap", baseDomain, task.plistPath]
            )
            if bootstrapResult.status != 0 && !isLoaded(serviceDomain) {
                try requireSuccess(bootstrapResult, action: "加载任务失败")
            }
        }
    }

    private static func trashTask(_ task: CaffeinateLaunchTask) throws {
        try validateUserTask(task)
        guard FileManager.default.fileExists(atPath: task.plistPath) else {
            throw MonitorActionError.missingConfiguration
        }

        try disableTask(task)
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: task.plistPath),
            resultingItemURL: nil
        )
    }

    private static func validateUserTask(_ task: CaffeinateLaunchTask) throws {
        guard task.scope == .userAgent else {
            throw MonitorActionError.permissionDenied
        }

        let allowedDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .standardizedFileURL
        let taskURL = URL(fileURLWithPath: task.plistPath).standardizedFileURL

        guard taskURL.deletingLastPathComponent() == allowedDirectory else {
            throw MonitorActionError.invalidTaskPath
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: taskURL.path),
           let owner = attributes[.ownerAccountID] as? NSNumber,
           owner.uint32Value != UInt32(getuid()) {
            throw MonitorActionError.permissionDenied
        }
    }

    private static func requireSuccess(
        _ result: CommandResult,
        action: String
    ) throws {
        guard result.status == 0 else {
            let detail = result.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "退出码 \(result.status)" : detail
            throw MonitorActionError.commandFailed("\(action)：\(suffix)")
        }
    }

    private static func isLoaded(_ serviceDomain: String) -> Bool {
        guard let result = try? ProcessRunner.run(
            "/bin/launchctl",
            ["print", serviceDomain]
        ) else {
            return false
        }
        return result.status == 0
    }

    private static func isDisabled(_ label: String, in baseDomain: String) -> Bool {
        guard let result = try? ProcessRunner.run(
            "/bin/launchctl",
            ["print-disabled", baseDomain]
        ), result.status == 0 else {
            return false
        }
        return SystemScanner.isServiceDisabled(label: label, in: result.standardOutput)
    }

    private static func waitUntilUnloaded(_ serviceDomain: String) -> Bool {
        for attempt in 0..<4 {
            if !isLoaded(serviceDomain) { return true }
            if attempt < 3 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return false
    }
}
