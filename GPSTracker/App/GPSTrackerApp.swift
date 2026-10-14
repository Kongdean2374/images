import SwiftUI
import SwiftData

@main
struct GPSTrackerApp: App {
    @StateObject private var settings = AppSettings.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            WorkoutSession.self,
            RoutePoint.self,
            LapRecord.self,
            WorkoutGoal.self
        ])
        return DatabaseHealth.makeContainer(schema: schema)
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(settings.preferDarkMode ? .dark : nil)
                .task {
                    await HealthKitImporter.shared.configure(container: sharedModelContainer)
                    await CalibrationCoordinator.shared.configure(container: sharedModelContainer)
                    await WorkoutExportRepository.configure(container: sharedModelContainer)
                    WorkoutInsightsStore.shared.configure(container: sharedModelContainer)
                    AppStartupState.shared.isReady = true
                    HealthKitManager.shared.refreshAvailability()
                    if settings.backgroundUpdates {
                        HealthBackgroundMonitor.shared.start()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
