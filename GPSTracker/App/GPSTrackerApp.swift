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
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // 資料庫損毀時退回記憶體模式，App 仍可使用
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [fallback])
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(settings.preferDarkMode ? .dark : nil)
        }
        .modelContainer(sharedModelContainer)
    }
}
