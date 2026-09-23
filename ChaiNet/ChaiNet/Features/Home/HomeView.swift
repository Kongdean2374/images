import SwiftUI
import ChaiNetCore

struct HomeView: View {
    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var latest: TestResult?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NetworkStatusCard(snapshot: app.currentNetwork)
                LatestResultCard(result: latest) { app.selectedTab = .speedTest }
                quickActions
                if app.speedTest.isRunning {
                    Button { app.selectedTab = .speedTest } label: {
                        Label("測速進行中，點此查看", systemImage: "speedometer").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("ChaiNet")
        .task(id: app.history.changeToken) { latest = app.history.results(limit: 1).first }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "常用測試")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                QuickAction(title: "測速", symbol: "speedometer", tint: Theme.download) { app.selectedTab = .speedTest }
                QuickActionLink(title: "遊戲", symbol: "gamecontroller.fill", tint: Theme.good) { ToolRunView(tool: .gaming) }
                QuickActionLink(title: "連續 Ping", symbol: "timer", tint: Theme.latency) { MonitorView() }
                QuickActionLink(title: "DNS", symbol: "globe", tint: Theme.info) { ToolRunView(tool: .dns) }
                QuickActionLink(title: "精靈", symbol: "wand.and.stars", tint: Theme.accent) { TroubleshootingWizardView() }
                QuickAction(title: "完整診斷", symbol: "stethoscope", tint: Theme.upload) { app.selectedTab = .diagnostics }
            }
        }
    }
}

private struct QuickAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) { QuickActionLabel(title: title, symbol: symbol, tint: tint) }.buttonStyle(.plain)
    }
}

private struct QuickActionLink<Destination: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let destination: () -> Destination
    var body: some View {
        NavigationLink { destination() } label: { QuickActionLabel(title: title, symbol: symbol, tint: tint) }.buttonStyle(.plain)
    }
}

private struct QuickActionLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border))
    }
}

struct NetworkStatusCard: View {
    let snapshot: NetworkSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Circle().fill(snapshot?.status == .satisfied ? Theme.good : Theme.critical).frame(width: 10, height: 10)
            }
            if let s = snapshot, s.status == .satisfied {
                HStack(spacing: 6) {
                    Badge(text: s.supportsIPv4 ? "IPv4" : "無 IPv4", color: s.supportsIPv4 ? Theme.good : Theme.textSecondary)
                    Badge(text: s.supportsIPv6 ? "IPv6" : "無 IPv6", color: s.supportsIPv6 ? Theme.good : Theme.textSecondary)
                    if s.vpn.state == .detected { Badge(text: "VPN", color: Theme.warning) }
                    if s.isExpensive { Badge(text: "計量", color: Theme.info) }
                    if s.isConstrained { Badge(text: "低數據", color: Theme.warning) }
                }
            }
        }
        .cardStyle()
    }

    private var icon: String {
        switch snapshot?.primaryInterface {
        case .wifi?: "wifi"
        case .cellular?: "antenna.radiowaves.left.and.right"
        case .wiredEthernet?: "cable.connector"
        default: "wifi.slash"
        }
    }

    private var title: String {
        guard let s = snapshot else { return "偵測網路中…" }
        guard s.status == .satisfied else { return "目前沒有網路" }
        return NetworkClass(snapshot: s).displayName
    }

    private var subtitle: String {
        guard let s = snapshot, s.status == .satisfied else { return "連線後即可開始測試" }
        if s.primaryInterface == .cellular, let rat = s.cellular?.radioTechnology {
            return Format.availability(rat) { "無線電：\($0.generationLabel)" } + " · 訊號強度：iOS 不提供"
        }
        return s.localAddresses.first { $0.family == .ipv4 }?.address ?? "已連線"
    }
}

private struct LatestResultCard: View {
    let result: TestResult?
    let startTest: () -> Void
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近一次測試").font(.headline)
                Spacer()
                if let r = result { Text(Format.relative(r.date)).font(.caption).foregroundStyle(Theme.textSecondary) }
            }
            if let r = result {
                let m = r.metrics
                NavigationLink { ResultDetailView(result: r) } label: {
                    HStack(spacing: 0) {
                        stat("下載", Format.speed(m.downloadMbps, settings: settings.settings), Theme.download)
                        stat("上傳", Format.speed(m.uploadMbps, settings: settings.settings), Theme.upload)
                        stat("Ping", Format.ms(m.idleLatencyMs), Theme.latency)
                        VStack(spacing: 2) {
                            Text("品質").font(.caption2).foregroundStyle(Theme.textSecondary)
                            Text(Format.score(r.scores.overall)).font(.headline.monospacedDigit()).foregroundStyle(Theme.scoreColor(r.scores.overall))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text("尚未有測試紀錄").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            PrimaryButton(title: "開始測速", symbol: "play.fill", action: startTest)
        }
        .cardStyle()
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(color)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
