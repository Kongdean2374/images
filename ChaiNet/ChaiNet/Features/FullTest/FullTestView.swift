import SwiftUI
import ChaiNetCore
import ChaiNetEngines

/// 完整測試（極限）: every measurable item, maximum load, user-chosen total time.
struct FullTestView: View {
    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var vm: RunViewModel?
    @State private var preset: Double? = 120
    @State private var customMinutes = 3
    @State private var customSeconds = 0
    @State private var forceMaxStreams = true
    @State private var multiServer = true

    private var totalSeconds: Double { preset ?? Double(customMinutes * 60 + customSeconds) }

    private var serverCount: Int {
        guard multiServer else { return 1 }
        let s = settings.settings.effective(for: "fullTest")
        return max(1, min(settings.allServers.count, max(2, s.autoServerCount)))
    }

    private var plan: FullTestPlan {
        FullTestPlan.make(totalSeconds: totalSeconds, serverCount: serverCount, forceMaxStreams: forceMaxStreams)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let vm {
                    switch vm.status {
                    case .idle:
                        setup(vm)
                    case .running:
                        ProgressHeader(vm: vm, estimated: vm.configuration?.fullTestPlan?.estimatedSeconds ?? plan.estimatedSeconds)
                        LiveRunView(vm: vm)
                        Button(role: .destructive) { vm.stop() } label: { Label("停止（保留已測資料）", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    case .finished, .cancelled:
                        if let r = vm.result {
                            ResultSummaryView(result: r)
                            TechnicalDetailsView(result: r)
                            RawDataCard(result: r)
                        }
                        PrimaryButton(title: "重新設定", symbol: "arrow.counterclockwise") { vm.reset() }
                    case .failed(let message):
                        EmptyStateView(symbol: "exclamationmark.triangle", title: "無法完成", message: message)
                        PrimaryButton(title: "返回設定", symbol: "arrow.counterclockwise") { vm.reset() }
                    }
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("完整測試（極限）")
        .navigationBarTitleDisplayMode(.inline)
        .featureSettings("fullTest", title: "完整測試")
        .onAppear { if vm == nil { vm = app.makeRunViewModel() } }
        .onDisappear { vm?.stop() }
    }

    @ViewBuilder
    private func setup(_ vm: RunViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("測試 iPhone 可量測的所有項目", systemImage: "bolt.horizontal.circle.fill").font(.headline).foregroundStyle(Theme.accent)
            Text("不限流量、最大負載：Ping、抖動、封包 / 連續遺失、突波、下載、上傳、Bufferbloat、多伺服器、多端點驗證、DNS、HTTP / TLS / QUIC、IPv4 / IPv6、Wi-Fi / 行動網路、MTU、路由追蹤、連續監測，以及遊戲 / 語音 / 串流 / OBS 判定。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()

        VStack(alignment: .leading, spacing: 12) {
            Text("總測試時間").font(.headline)
            Picker("時間", selection: $preset) {
                ForEach(FullTestPlan.presets, id: \.self) { Text("\(Int($0 / 60)) 分").tag(Double?.some($0)) }
                Text("自訂").tag(Double?.none)
            }
            .pickerStyle(.segmented)
            if preset == nil {
                HStack {
                    Stepper("\(customMinutes) 分", value: $customMinutes, in: 1...30)
                    Stepper("\(customSeconds) 秒", value: $customSeconds, in: 0...55, step: 5)
                }
                .font(.subheadline)
            }
            Toggle("強制 16 條平行連線（極限負載）", isOn: $forceMaxStreams)
            Toggle("多伺服器（自動選取 \(serverCount) 台）", isOn: $multiServer)
            if settings.allServers.count < 2 && multiServer {
                Text("目前只有 1 台伺服器；加入自架伺服器後即可多台比較。多端點驗證仍會量測 Cloudflare / Google / Quad9 / Apple。")
                    .font(.caption2).foregroundStyle(Theme.warning)
            }
        }
        .cardStyle()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("各項時間分配").font(.headline)
                Spacer()
                Text("約 \(Int(plan.estimatedSeconds / 60)) 分 \(Int(plan.estimatedSeconds) % 60) 秒").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            ForEach(plan.items) { item in
                KeyValueRow(key: item.title, value: (item.budgeted ? "" : "約 ") + "\(Int(item.seconds.rounded())) 秒",
                            valueColor: item.budgeted ? Theme.textPrimary : Theme.textSecondary)
            }
            Text("下載 / 上傳每台伺服器各 \(Int(plan.throughputSeconds)) 秒；路由追蹤與 MTU 依網路狀況而定。").font(.caption2).foregroundStyle(Theme.textSecondary)
            if app.onCellular {
                Label("目前使用行動網路：極限測試會不限流量，可能消耗數 GB 數據。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .cardStyle()

        PrimaryButton(title: "開始完整測試", symbol: "play.fill") { start(vm) }
        Text("測試期間請保持 App 在前景；進入背景會停止並保留已完成的部分。").font(.caption2).foregroundStyle(Theme.textSecondary)
    }

    private func start(_ vm: RunViewModel) {
        vm.featureID = "fullTest"
        let effective = settings.settings.effective(for: "fullTest")
        let plan = plan
        var config = TestRunConfiguration.extreme(plan: plan, servers: settings.allServers,
                                                  fixedServer: effective.serverPlan(available: settings.allServers).primary,
                                                  settings: effective, onCellular: app.onCellular)
        config.autoAdditionalServerCount = max(0, plan.serverCount - 1)
        vm.start(config)
    }
}

private struct ProgressHeader: View {
    let vm: RunViewModel
    let estimated: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = vm.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("完整測試進行中").font(.headline)
                    Spacer()
                    Text("\(Self.mmss(elapsed)) / 約 \(Self.mmss(estimated))").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                ProgressView(value: min(elapsed / max(estimated, 1), 1)).tint(Theme.accent)
            }
            .cardStyle()
        }
    }

    static func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}
