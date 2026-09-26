import SwiftUI
import ChaiNetCore
import ChaiNetEngines

/// Toolbox: one stress engine on its own. It uses the same engines, data model and analysis as the
/// Extreme Stress Test; only the parameters are chosen by the user.
struct StressToolView: View {
    let tool: Tool
    let kind: StressToolKind

    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var vm: RunViewModel?
    @State private var duration: Double = 20
    @State private var maxStreams = 32
    @State private var burstCycles = 10
    @State private var targetNodeID: String?
    @State private var dataLimitMB: Int?
    @State private var limitInitialized = false
    @State private var confirming = false

    private var nodes: [StressNode] { TestRunner.defaultStressNodes(servers: settings.allServers).filter(\.isThroughputCapable) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let vm {
                    switch vm.status {
                    case .idle:
                        setup(vm)
                    case .running:
                        if let p = vm.stressProgress {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.kind.title).font(.headline)
                                Text("已用流量 ↓ \(Format.bytes(p.downloadBytes)) ↑ \(Format.bytes(p.uploadBytes))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle()
                        }
                        LiveRunView(vm: vm)
                        Button(role: .destructive) { vm.stop() } label: { Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    case .finished, .cancelled:
                        if let r = vm.result { result(r) }
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
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if vm == nil { vm = app.makeRunViewModel() }
            if !limitInitialized {
                limitInitialized = true
                if app.onCellular { dataLimitMB = 1_500 }
            }
        }
        .onDisappear { vm?.stop() }
    }

    // MARK: Setup

    @ViewBuilder
    private func setup(_ vm: RunViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(kind.title, systemImage: tool.symbol).font(.headline).foregroundStyle(Theme.critical)
            Text(tool.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
            Text("與極限壓力測試使用相同的引擎：先量 5 秒閒置基準（固定對照探測），負載期間持續量延遲，結束後量恢復。")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()

        VStack(alignment: .leading, spacing: 10) {
            Text("參數").font(.headline)
            if usesDuration {
                Stepper(kind == .streamRamp ? "每級 \(Int(duration)) 秒" : "負載時間 \(Int(duration)) 秒", value: $duration,
                        in: (kind == .streamRamp ? 3 : 10)...(kind == .streamRamp ? 20 : 300), step: kind == .streamRamp ? 1 : 10)
                    .font(.subheadline)
            }
            if usesStreams {
                Stepper("最多連線數 \(maxStreams)", value: $maxStreams, in: 1...32).font(.subheadline)
            }
            if kind == .burst {
                Stepper("突發次數 \(burstCycles)（3 秒負載 / 2 秒閒置）", value: $burstCycles, in: 5...10).font(.subheadline)
            }
            if kind != .multiDestination && kind != .packetLossStress {
                HStack {
                    Text("目標節點").font(.subheadline)
                    Spacer()
                    Picker("目標節點", selection: $targetNodeID) {
                        Text("自動（Cloudflare）").tag(String?.none)
                        ForEach(nodes.filter { $0.provider != .mlab }) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                }
            }
            HStack {
                Text("流量上限").font(.subheadline)
                Spacer()
                Picker("流量上限", selection: $dataLimitMB) {
                    Text("不限").tag(Int?.none)
                    ForEach(StressDataLimits.capPresetsMB, id: \.self) { Text(StressTestView.mbText($0)).tag(Int?.some($0)) }
                }
                .pickerStyle(.menu)
            }
            if kind == .packetLossStress {
                Text("封包遺失壓力：50 pps 壓力探測 + 5 pps 對照探測；只對允許的端點，不做洪水攻擊。").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            if app.onCellular {
                Label("正在使用行動數據：預設上限 1.5 GB，達到後自動停止負載。", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2).foregroundStyle(Theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()

        PrimaryButton(title: "開始", symbol: "play.fill") { confirming = true }
            .alert("開始\(kind.title)？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("開始", role: .destructive) { start(vm) }
            } message: {
                Text("此測試會讓網路滿載並使用大量流量" + (dataLimitMB.map { "（上限 \(StressTestView.mbText($0))）" } ?? "（未設定上限）") + "。")
            }
    }

    private var usesDuration: Bool { ![.burst, .packetLossStress].contains(kind) }
    private var usesStreams: Bool { ![.recovery, .packetLossStress, .multiDestination].contains(kind) }

    private func start(_ vm: RunViewModel) {
        vm.featureID = tool.rawValue
        let request = StressToolRequest(kind: kind, durationSeconds: duration, maxStreams: maxStreams, burstCycles: burstCycles,
                                        targetNodeID: targetNodeID, dataLimitBytes: dataLimitMB.map { Int64($0) * StressDataLimits.megabyte })
        vm.start(kind: .stressTool, items: [], onCellular: app.onCellular, adjust: { config in
            config.stressTool = request
            config.settings.trafficUsage = .unlimited
        })
    }

    // MARK: Result

    @ViewBuilder
    private func result(_ r: TestResult) -> some View {
        if vm?.status == .cancelled {
            Label("測試已停止：以下為已完成的部分", systemImage: "pause.circle").font(.footnote).foregroundStyle(Theme.warning)
        }
        if let report = r.stressLoad {
            StressLoadSummaryCard(report: report, standardDownloadMbps: nil, standardUploadMbps: nil)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                MetricTile(title: "閒置延遲", value: Format.number(r.idleLatency?.rtt?.median, digits: 0), unit: "ms", caption: "對照探測基準", symbol: "timer", tint: Theme.latency)
                if let loss = r.packetLoss {
                    MetricTile(title: "封包遺失", value: Format.number(loss.loss.lossPercent, digits: 2), unit: "%", caption: r.packetLossMethod, symbol: "checkmark.shield", tint: Theme.good)
                }
                StressLoadTiles(report: report)
            }
            StressLoadTechnicalSections(report: report)
        }
        NavigationLink { StressToolTechnicalView(result: r) } label: {
            Label("查看完整技術資料與匯出", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

private struct StressToolTechnicalView: View {
    let result: TestResult
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TechnicalDetailsView(result: result)
                RawDataCard(result: result)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("完整技術資料")
        .navigationBarTitleDisplayMode(.inline)
    }
}
