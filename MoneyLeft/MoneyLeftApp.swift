import SwiftUI
import SwiftData

@main
struct MoneyLeftApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var liveActivity = LiveActivityController.shared
    @StateObject private var appLock = AppLockController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(liveActivity)
                .environmentObject(appLock)
                .tint(Theme.accent)
        }
        .modelContainer(AppContainer.shared)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                let context = AppContainer.context
                DefaultData.seedIfNeeded(context: context)
                BudgetService.refreshWidgetSnapshot(context: context)
                LiveActivityController.shared.syncOnForeground(context: context)
                NotificationService.syncDailyReminder()
                NotificationService.scheduleOverspendAlertIfNeeded(
                    summary: BudgetService.summary(in: context)
                )
                appLock.unlockIfDisabled()
                appLock.authenticate()
            case .background:
                appLock.lockIfNeeded()
            default:
                break
            }
        }
    }
}
