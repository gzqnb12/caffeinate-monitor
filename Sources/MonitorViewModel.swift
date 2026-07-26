import AppKit
import Foundation

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var processes: [RunningCaffeinate] = []
    @Published private(set) var tasks: [CaffeinateLaunchTask] = []
    @Published private(set) var powerSchedule = PowerScheduleSnapshot(
        repeatingEvents: [],
        systemEvents: [],
        rawOutput: ""
    )
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPerformingAction = false
    @Published var banner: BannerMessage?

    struct BannerMessage: Identifiable {
        let id = UUID()
        let isError: Bool
        let text: String
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let snapshot = await Task.detached(priority: .utility) {
            SystemScanner.capture()
        }.value

        processes = snapshot.processes
        tasks = snapshot.tasks
        powerSchedule = snapshot.powerSchedule
        lastUpdated = snapshot.capturedAt
        isRefreshing = false

        if !snapshot.errors.isEmpty {
            banner = BannerMessage(
                isError: true,
                text: snapshot.errors.joined(separator: "\n")
            )
        }
    }

    func perform(_ action: MonitorAction) async {
        guard !isPerformingAction else { return }
        isPerformingAction = true

        let outcome = await Task.detached(priority: .userInitiated) {
            MonitorActions.perform(action)
        }.value

        banner = BannerMessage(
            isError: !outcome.isSuccess,
            text: outcome.message
        )
        isPerformingAction = false
        await refresh()
    }

    func reveal(_ task: CaffeinateLaunchTask) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: task.plistPath)
        ])
    }

    func copyToPasteboard(_ text: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        banner = BannerMessage(isError: false, text: confirmation)
    }
}
