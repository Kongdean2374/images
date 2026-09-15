import SwiftUI

struct RootView: View {
    @State private var selection = 0

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
    }
}
