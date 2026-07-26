import AppKit
import Combine
import SwiftUI

struct DashboardView: View {
    @StateObject private var model = MonitorViewModel()
    @State private var pendingAction: MonitorAction?
    @State private var showsSystemPowerEvents = false

    private let refreshTimer = Timer.publish(
        every: 5,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    if let banner = model.banner {
                        bannerView(banner)
                    }

                    summaryCards
                    runningSection
                    configuredSection
                    powerScheduleSection
                }
                .padding(22)
            }
        }
        .frame(minWidth: 860, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.refresh()
        }
        .onReceive(refreshTimer) { _ in
            Task { await model.refresh() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await model.refresh() }
        }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { isPresented in
                    if !isPresented { pendingAction = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(
                    action.confirmLabel,
                    role: action.isDestructive ? .destructive : nil
                ) {
                    pendingAction = nil
                    Task { await model.perform(action) }
                }
                Button("取消", role: .cancel) {
                    pendingAction = nil
                }
            }
        } message: {
            if let action = pendingAction {
                Text(action.message)
            }
        }
        .disabled(model.isPerformingAction)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Caffeinate 管理器")
                    .font(.title2.weight(.semibold))
                Text("查看当前防休眠进程、定时任务和自动唤醒计划")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let lastUpdated = model.lastUpdated {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("上次刷新")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(lastUpdated, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.bordered)
            .help("立即刷新")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var summaryCards: some View {
        HStack(spacing: 14) {
            SummaryCard(
                title: "正在保持唤醒",
                value: model.processes.count,
                icon: "moon.zzz.fill",
                tint: .green,
                detail: model.processes.isEmpty ? "当前没有运行" : "每 5 秒刷新"
            )
            SummaryCard(
                title: "已配置任务",
                value: model.tasks.count,
                icon: "calendar.badge.clock",
                tint: .indigo,
                detail: model.tasks.filter { !$0.isDisabled }.isEmpty
                    ? "没有已启用任务"
                    : "\(model.tasks.filter { !$0.isDisabled }.count) 个已启用"
            )
            SummaryCard(
                title: "重复唤醒计划",
                value: model.powerSchedule.repeatingEvents.count,
                icon: "power",
                tint: .orange,
                detail: "由 pmset 管理"
            )
        }
    }

    private var runningSection: some View {
        SectionCard(
            title: "正在运行的 caffeinate",
            subtitle: "这里只显示此刻真实存在的进程；任务结束后会自动消失。",
            icon: "waveform.path.ecg"
        ) {
            if model.processes.isEmpty {
                EmptyState(
                    icon: "checkmark.circle",
                    title: "当前没有 caffeinate 正在保持唤醒",
                    message: "这很正常。定时任务只有在执行期间才会出现在这里。"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(model.processes) { process in
                        ProcessRow(
                            process: process,
                            onCopy: {
                                model.copyToPasteboard(
                                    process.redactedCommand,
                                    confirmation: "已复制脱敏后的命令。"
                                )
                            },
                            onStop: process.isOwnedByCurrentUser
                                ? { pendingAction = .stopProcess(process) }
                                : nil
                        )
                        if process.id != model.processes.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
    }

    private var configuredSection: some View {
        SectionCard(
            title: "已配置的 caffeinate 定时任务",
            subtitle: "即使任务当前没有运行，只要 launchd 配置中调用了 caffeinate，就会显示在这里。",
            icon: "clock.badge.checkmark"
        ) {
            if model.tasks.isEmpty {
                EmptyState(
                    icon: "calendar.badge.exclamationmark",
                    title: "未发现相关 launchd 任务",
                    message: "脚本内部间接调用 caffeinate 的任务可能无法自动识别。"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(model.tasks) { task in
                        LaunchTaskRow(
                            task: task,
                            onRun: task.canManage && task.isLoaded && !task.isDisabled
                                ? { pendingAction = .runTask(task) }
                                : nil,
                            onToggle: task.canManage
                                ? {
                                    pendingAction = task.isDisabled
                                        ? .enableTask(task)
                                        : .disableTask(task)
                                }
                                : nil,
                            onReveal: { model.reveal(task) },
                            onTrash: task.canManage
                                ? { pendingAction = .trashTask(task) }
                                : nil
                        )
                        if task.id != model.tasks.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
    }

    private var powerScheduleSection: some View {
        SectionCard(
            title: "自动唤醒计划",
            subtitle: "自动唤醒由 pmset 管理，不是 caffeinate；停用定时任务不会自动取消这里的计划。",
            icon: "bolt.badge.clock"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if model.powerSchedule.repeatingEvents.isEmpty {
                    EmptyState(
                        icon: "power",
                        title: "没有重复电源计划",
                        message: "macOS 自己维护的一次性事件仍可能显示在下方。"
                    )
                } else {
                    ForEach(
                        Array(model.powerSchedule.repeatingEvents.enumerated()),
                        id: \.offset
                    ) { _, event in
                        HStack(spacing: 10) {
                            Image(systemName: "wake")
                                .foregroundStyle(.orange)
                                .frame(width: 24)
                            Text(event)
                                .font(.body)
                            Spacer()
                            Text("重复")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("取消命令会移除整台 Mac 的全部重复电源计划，请先检查列表。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("复制取消命令") {
                            model.copyToPasteboard(
                                "sudo pmset repeat cancel",
                                confirmation: "已复制取消重复电源计划的命令。"
                            )
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }

                if !model.powerSchedule.systemEvents.isEmpty {
                    DisclosureGroup(
                        isExpanded: $showsSystemPowerEvents
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(
                                Array(model.powerSchedule.systemEvents.enumerated()),
                                id: \.offset
                            ) { _, event in
                                Text(event)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("macOS 管理的一次性事件（\(model.powerSchedule.systemEvents.count)）")
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: MonitorViewModel.BannerMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(banner.text)
                .font(.subheadline)
                .textSelection(.enabled)
            Spacer()
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(banner.isError ? .red : .green)
        .padding(12)
        .background(
            (banner.isError ? Color.red : Color.green).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }
}

private struct SummaryCard: View {
    let title: String
    let value: Int
    let icon: String
    let tint: Color
    let detail: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(value)")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 28, height: 28)
                    .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()
            content
                .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

private struct ProcessRow: View {
    let process: RunningCaffeinate
    let onCopy: () -> Void
    let onStop: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
                .frame(width: 34, height: 34)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(process.modeSummary)
                        .font(.subheadline.weight(.semibold))
                    StatusBadge(text: "PID \(process.pid)", color: .gray)
                    StatusBadge(text: process.elapsed, color: .green)
                    if !process.isOwnedByCurrentUser {
                        StatusBadge(text: process.user, color: .orange)
                    }
                }

                Text(process.redactedCommand)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 14)

            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制脱敏命令")

            if let onStop {
                Button("停止…", role: .destructive, action: onStop)
                    .controlSize(.small)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("其他用户的进程只读")
            }
        }
        .padding(.vertical, 7)
    }
}

private struct LaunchTaskRow: View {
    let task: CaffeinateLaunchTask
    let onRun: (() -> Void)?
    let onToggle: (() -> Void)?
    let onReveal: () -> Void
    let onTrash: (() -> Void)?

    private var stateColor: Color {
        if task.isDisabled { return .secondary }
        if task.isRunning { return .green }
        if task.isLoaded { return .indigo }
        return .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.isRunning ? "play.circle.fill" : "calendar.badge.clock")
                .font(.system(size: 18))
                .foregroundStyle(stateColor)
                .frame(width: 34, height: 34)
                .background(stateColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(task.displayName)
                        .font(.subheadline.weight(.semibold))
                    StatusBadge(text: task.stateLabel, color: stateColor)
                    StatusBadge(text: task.scope.rawValue, color: .gray)
                    StatusBadge(
                        text: task.confidence.rawValue,
                        color: task.confidence == .direct ? .green : .orange
                    )
                }

                Text(task.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Label(task.schedule, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(task.redactedInvocation)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 14)

            Menu {
                if let onRun {
                    Button("立即运行…", systemImage: "play.fill", action: onRun)
                }
                Button("在 Finder 中显示", systemImage: "folder", action: onReveal)

                if let onToggle {
                    Divider()
                    Button(
                        task.isDisabled ? "启用任务…" : "停用任务…",
                        systemImage: task.isDisabled ? "checkmark.circle" : "pause.circle",
                        action: onToggle
                    )
                }
                if let onTrash {
                    Button(
                        "移到废纸篓…",
                        systemImage: "trash",
                        role: .destructive,
                        action: onTrash
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 7)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.11), in: Capsule())
            .foregroundStyle(color)
    }
}
