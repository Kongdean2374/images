import SwiftUI
import ChaiNetCore

/// Six-destination navigation with a custom bottom bar (the system TabView collapses more than
/// five tabs into "More").
struct RootView: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        @Bindable var app = app
        // The tab bar is a real layout region (not an overlay), so scroll views / Lists / Forms
        // end above it and their last row is never hidden.
        VStack(spacing: 0) {
            Group {
                switch app.selectedTab {
                case .home: NavigationStack { HomeView() }
                case .speedTest: NavigationStack { SpeedTestView() }
                case .tools: NavigationStack { ToolsView() }
                case .diagnostics: NavigationStack { DiagnosticsView() }
                case .history: NavigationStack { HistoryView() }
                case .settings: NavigationStack { SettingsView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabBar(selection: $app.selectedTab, speedTestRunning: app.speedTest.isRunning)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await app.observeNetwork() }
        .task { app.applyRetention() }
    }
}

private struct TabBar: View {
    @Binding var selection: AppTab
    let speedTestRunning: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.symbol).font(.system(size: 18, weight: .semibold))
                            if tab == .speedTest && speedTestRunning {
                                Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 6, y: -2)
                            }
                        }
                        Text(tab.title).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selection == tab ? Theme.accent : Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}
