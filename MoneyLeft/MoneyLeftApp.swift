import SwiftUI
import SwiftData

@main
struct MoneyLeftApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var liveActivity = LiveActivityController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(liveActivity)
                .tint(Color(hex: "#0A84FF"))
        }
        .modelContainer(AppContainer.shared)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            let context = AppContainer.context
            DefaultData.seedIfNeeded(context: context)
            BudgetService.refreshWidgetSnapshot(context: context)
            LiveActivityController.shared.syncOnForeground(context: context)
        }
    }
}
