import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var selection: Tab = .home
    @State private var showingEditor = false
    @State private var showingReceiptFlow = false

    enum Tab: Hashable { case home, stats, settings }

    var body: some View {
        TabView(selection: $selection) {
            HomeView(showingEditor: $showingEditor, showingReceiptFlow: $showingReceiptFlow)
                .tabItem { Label("首頁", systemImage: "house.fill") }
                .tag(Tab.home)

            StatsView()
                .tabItem { Label("報表", systemImage: "chart.bar.fill") }
                .tag(Tab.stats)

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .onAppear {
            DefaultData.seedIfNeeded(context: context)
            BudgetService.refreshWidgetSnapshot(context: context)
        }
        .onOpenURL { url in
            handle(url)
        }
        .sheet(isPresented: $showingEditor) {
            ExpenseEditorView()
        }
        .sheet(isPresented: $showingReceiptFlow) {
            ReceiptFlowView()
        }
    }

    /// moneyleft://add 、 moneyleft://scan
    private func handle(_ url: URL) {
        guard url.scheme == AppGroup.urlScheme else { return }
        selection = .home
        switch url.host {
        case "add": showingEditor = true
        case "scan": showingReceiptFlow = true
        default: break
        }
    }
}
