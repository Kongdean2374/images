import SwiftUI
import ChaiNetCore

/// Commercial-grade speed test: Ping → Download → Upload with a live chart.
struct SpeedTestView: View {
    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings

    static let speedTestItems: Set<TestItem> = [.ping, .jitter, .packetLoss, .download, .upload, .bufferbloat]

    private var vm: RunViewModel { app.speedTest }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch vm.status {
                case .idle:
                    StartPanel(onStart: start)
                case .running:
                    LiveRunView(vm: vm)
                    Button(role: .destructive) { vm.stop() } label: {
                        Label("停止測試", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                case .finished, .cancelled:
                    if let r = vm.result {
                        ResultSummaryView(result: r)
                        TechnicalDetailsView(result: r)
                    }
                    PrimaryButton(title: "再測一次", symbol: "arrow.clockwise", action: start)
                case .failed(let message):
                    EmptyStateView(symbol: "exclamationmark.triangle", title: "測試失敗", message: message)
                    PrimaryButton(title: "重試", symbol: "arrow.clockwise", action: start)
                }
            }
            .padding()
            .animation(.snappy, value: vm.status)
        }
        .screenBackground()
        .navigationTitle("測速")
        .featureSettings("speedTest", title: "測速")
        .toolbar {
            if let r = vm.result, !vm.isRunning {
                ShareLink(item: ResultExporter.shareSummary(r)) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }

    private func start() {
        let items: Set<TestItem>
        switch settings.settings.defaultTestMode {
        case .speedTest:
            items = Self.speedTestItems
        case .customProfile:
            items = settings.settings.allProfiles.first { $0.id == settings.settings.defaultProfileID }?.items ?? Self.speedTestItems
        case .fullDiagnostics:
            items = TestProfile.fullDiagnostics.items
        }
        vm.featureID = "speedTest"
        vm.start(kind: .fullSpeedTest, items: items, onCellular: app.onCellular)
    }
}

private struct StartPanel: View {
    let onStart: () -> Void
    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var pulse = false

    var body: some View {
        let s = settings.settings.effective(for: "speedTest")
        VStack(spacing: 22) {
            Button(action: onStart) {
                ZStack {
                    Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 14).scaleEffect(pulse ? 1.08 : 0.96)
                    Circle().fill(Theme.accent.gradient).padding(18)
                    Text("開始").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.85))
                }
                .frame(width: 210, height: 210)
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
            .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true } }
            .accessibilityLabel("開始測速")

            VStack(spacing: 8) {
                KeyValueRow(key: "流程", value: "Ping → 下載 → 上傳")
                KeyValueRow(key: "伺服器", value: s.serverSelection.displayName)
                KeyValueRow(key: "時間 / 連線數", value: "\(s.testDuration.displayName) · \(s.parallelConnections.displayName)")
                if app.onCellular {
                    KeyValueRow(key: "行動數據", value: s.trafficUsage == .saveOnCellular ? "節省模式（約 ≤ 150 MB）" : "可能使用數百 MB",
                                valueColor: Theme.warning)
                }
            }
            .cardStyle()
            NetworkStatusCard(snapshot: app.currentNetwork)
        }
    }
}
