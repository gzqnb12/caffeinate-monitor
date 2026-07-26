import SwiftUI

@main
struct CaffeinateMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
        .defaultSize(width: 940, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
