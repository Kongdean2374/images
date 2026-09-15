import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0
    @State private var didAutoImport = false
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { HomeView() }
                .tabItem { Label("開始", systemImage: "bolt.horizontal.circle.fill") }
                .tag(0)

            NavigationStack { HistoryListView() }
                .tabItem { Label("紀錄", systemImage: "list.bullet.rectangle.portrait") }
                .tag(1)

            NavigationStack { AnalyticsView() }
                .tabItem { Label("分析", systemImage: "chart.xyaxis.line") }
                .tag(2)

            NavigationStack { PBDashboardView() }
                .tabItem { Label("成就", systemImage: "trophy.fill") }
                .tag(3)

            NavigationStack { SettingsView() }
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(Theme.accent)
        .onAppear {
            if !settings.hasSeenOnboarding { showOnboarding = true }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            NavigationStack {
                OnboardingView()
            }
        }
        .task {
            guard !didAutoImport else { return }
            didAutoImport = true
            guard settings.autoImportHealth, HealthKitManager.shared.isReady else { return }
            await HealthKitImporter.shared.importNew(context: context, existing: sessions)
            if settings.backgroundUpdates {
                await HealthBackgroundMonitor.shared.checkDailyGoals()
            }
        }
    }
}
