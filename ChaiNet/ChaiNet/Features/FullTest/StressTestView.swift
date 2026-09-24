import SwiftUI
import ChaiNetCore
import ChaiNetEngines

/// 極限壓力測試: maximum load on every node, long enough to see degradation. The only choice
/// is the total duration; streams, rates and nodes are fixed at maximum.
struct StressTestView: View {
    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var vm: RunViewModel?
    @State private var preset: Double? = 300
    @State private var customMinutes = 20
    @State private var confirming = false

    private var totalSeconds: Double { preset ?? Double(customMinutes * 60) }
    private var nodes: [StressNode] { TestRunner.defaultStressNodes(servers: settings.allServers) }
    private var plan: StressTestPlan { StressTestPlan.make(totalSeconds: totalSeconds, nodes: nodes) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let vm {
                    switch vm.status {
                    case .idle:
                        setup(vm)
                    case .running:
                        StressProgressHeader(vm: vm, estimated: vm.configuration?.stressPlan?.estimatedSeconds ?? plan.estimatedSeconds)
                        LiveRunView(vm: vm)
                        Button(role: .destructive) { vm.stop() } label: { Label("停止（保留已測資料）", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    case .finished, .cancelled:
                        if let r = vm.result {
                            if vm.status == .cancelled {
                                Label("測試已停止：以下為已完成的部分", systemImage: "pause.circle").font(.footnote).foregroundStyle(Theme.warning)
                            }
                            StressResultView(result: r)
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
        .navigationTitle("極限壓力測試")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if vm == nil { vm = app.makeRunViewModel() } }
        .onDisappear { vm?.stop() }
    }

    // MARK: Setup

    @ViewBuilder
    private func setup(_ vm: RunViewModel) -> some View {
        let plan = plan
        let network = app.currentNetwork
        let cls = network.map(NetworkClass.init(snapshot:)) ?? .unknown
        let rates = StressTestPlan.assumedMbps(history: app.history.results(limit: 200), networkClass: cls)
        let traffic = plan.trafficEstimate(downloadMbps: rates.download, uploadMbps: rates.upload)

        VStack(alignment: .leading, spacing: 8) {
            Label("最大強度 · 多節點 · 多輪", systemImage: "flame.fill").font(.headline).foregroundStyle(Theme.critical)
            Text("每個吞吐量節點以最大負載（HTTP 16 條連線、M-Lab NDT7）反覆下載 / 上傳，同時量測負載延遲、50 pps ICMP 壓力探測與低頻對照探測、負載後恢復、跨業者一致性、DNS / 協定、IPv4 / IPv6、路由與 MTU。測試時間越長，重複輪數越多。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()

        VStack(alignment: .leading, spacing: 12) {
            Text("測試時間").font(.headline)
            Picker("時間", selection: $preset) {
                ForEach(StressTestPlan.presets, id: \.self) { Text("\(Int($0 / 60)) 分").tag(Double?.some($0)) }
                Text("自訂").tag(Double?.none)
            }
            .pickerStyle(.segmented)
            if preset == nil {
                Stepper("\(customMinutes) 分鐘", value: $customMinutes, in: 1...60).font(.subheadline)
            }
        }
        .cardStyle()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("測試計畫").font(.headline)
                Spacer()
                Text("預估 \(StressProgressHeader.mmss(plan.estimatedSeconds)) · \(plan.rounds) 輪").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            ForEach(plan.totalsByKind, id: \.kind) { item in
                KeyValueRow(key: item.kind.title, value: "\(Int(item.seconds.rounded())) 秒")
            }
            Text("每個節點每輪下載 / 上傳各 \(Int(plan.transferSeconds.rounded())) 秒（M-Lab NDT7 依協定上限 10 秒）；健康檢查未通過的節點會略過，不影響整體測試。")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()

        VStack(alignment: .leading, spacing: 6) {
            Text("預估流量").font(.headline)
            KeyValueRow(key: "下載", value: Format.bytes(traffic.downloadBytes))
            KeyValueRow(key: "上傳", value: Format.bytes(traffic.uploadBytes))
            KeyValueRow(key: "合計", value: Format.bytes(traffic.totalBytes), valueColor: Theme.critical)
            Text(rates.fromHistory
                 ? "依此網路類型最近結果（下載 \(Format.number(rates.download, digits: 0)) / 上傳 \(Format.number(rates.upload, digits: 0)) Mbps）估算；實際流量依網路速度而定。"
                 : "尚無此網路類型的紀錄，以典型速度（下載 \(Format.number(rates.download, digits: 0)) / 上傳 \(Format.number(rates.upload, digits: 0)) Mbps）估算；實際可能更多。")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()

        VStack(alignment: .leading, spacing: 6) {
            Text("網路與節點").font(.headline)
            KeyValueRow(key: "網路類型", value: network.map { "\(cls.displayName) · \($0.primaryInterface.displayName)" } ?? "偵測中…")
            ForEach(plan.throughputNodes) { node in
                KeyValueRow(key: node.name, value: "吞吐量 + 延遲（\(node.provider == .mlab ? "NDT7 ×1" : "HTTP ×16")）")
            }
            ForEach(plan.latencyOnlyNodes) { node in
                KeyValueRow(key: node.name, value: "僅延遲 / 協定", valueColor: Theme.textSecondary)
            }
            Text("Google / Apple / Quad9 / DNS 節點只用於延遲、遺失、TCP、TLS、HTTP、DNS、QUIC 與路由，絕不用於大量下載 / 上傳。")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()

        VStack(alignment: .leading, spacing: 8) {
            Label(StressTestPlan.confirmationWarning, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(Theme.warning)
            if let network {
                ForEach(StressTestPlan.warnings(for: network), id: \.self) { w in
                    Text("• " + w).font(.caption).foregroundStyle(Theme.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()

        PrimaryButton(title: "開始極限壓力測試", symbol: "flame.fill") { confirming = true }
            .alert("開始極限壓力測試？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("我了解，開始", role: .destructive) { start(vm, plan: plan) }
            } message: {
                Text(StressTestPlan.confirmationWarning + "\n預估流量 \(Format.bytes(traffic.totalBytes))，約 \(StressProgressHeader.mmss(plan.estimatedSeconds))。")
            }
        Text("測試期間請保持 App 在前景；進入背景會停止並保留已完成的部分。").font(.caption2).foregroundStyle(Theme.textSecondary)
    }

    private func start(_ vm: RunViewModel, plan: StressTestPlan) {
        var s = settings.settings
        s.trafficUsage = .unlimited
        var config = TestRunConfiguration(kind: .extremeStressTest, items: [], candidateServers: settings.allServers,
                                          settings: s, onCellular: app.onCellular)
        config.stressPlan = plan
        config.stressWarnings = app.currentNetwork.map(StressTestPlan.warnings(for:)) ?? []
        vm.start(config)
    }
}

// MARK: - Progress

private struct StressProgressHeader: View {
    let vm: RunViewModel
    let estimated: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = vm.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline).lineLimit(1)
                    Spacer()
                    Text("\(Self.mmss(elapsed)) / 約 \(Self.mmss(estimated))").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                ProgressView(value: min(elapsed / max(estimated, 1), 1)).tint(Theme.critical)
                if let p = vm.stressProgress {
                    Text("階段 \(p.phaseIndex) / \(p.phaseCount) · 已用流量 ↓ \(Format.bytes(p.downloadBytes)) ↑ \(Format.bytes(p.uploadBytes))")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
            .cardStyle()
        }
    }

    private var title: String {
        guard let p = vm.stressProgress else { return "極限壓力測試進行中" }
        var t = p.kind.title
        if let r = p.round { t += " · 第 \(r) 輪" }
        if let n = p.nodeName { t += " · \(n)" }
        return t
    }

    static func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

// MARK: - Result

/// Simple result screen (tiles) with links to the full technical data and exports.
struct StressResultView: View {
    let result: TestResult
    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var aiURL: URL?
    @State private var engineerIPs = false
    @State private var engineerURL: URL?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        if let s = result.stress {
            VStack(spacing: 12) {
                HStack {
                    ScoreRing(score: s.score, label: "壓力分數", size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("極限壓力測試").font(.headline)
                        Text("\(s.plan.rounds) 輪 · \(s.plan.throughputNodes.count) 個吞吐量節點 · \(s.controlProbes.count) 個對照探測")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        Text(s.lossConfirmation.verdict.displayName).font(.caption2).foregroundStyle(Theme.textSecondary)
                        if let c = s.scoreConfidence {
                            Text("分數信心：\(c.displayName)").font(.caption2).foregroundStyle(c == .high ? Theme.textSecondary : Theme.warning)
                        }
                        if !s.invalidTransfers().isEmpty {
                            Text("\(s.invalidTransfers().count) 次傳輸無效，已排除於統計與分數").font(.caption2).foregroundStyle(Theme.warning)
                        }
                    }
                    Spacer()
                }
                .cardStyle()

                LazyVGrid(columns: columns, spacing: 12) { tiles(s) }

                NavigationLink { StressTechnicalView(result: result) } label: {
                    Label("查看完整技術資料", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let aiURL {
                    ShareLink(item: aiURL) { Label("匯出 AI 分析", systemImage: "sparkles").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
                VStack(spacing: 6) {
                    Toggle("Engineer 匯出包含完整 IP 位址", isOn: $engineerIPs).font(.footnote)
                    if let engineerURL {
                        ShareLink(item: engineerURL) { Label("匯出 Raw Engineer Data", systemImage: "curlybraces").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    Text("AI 分析匯出會把所有 IP 位址遮蔽為 [REDACTED]；Engineer 匯出為 JSON，預設同樣遮蔽，可自行選擇包含。")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .cardStyle()
            }
            .task(id: "\(result.id)-\(engineerIPs)") { buildExports() }
        } else {
            ResultSummaryView(result: result)
        }
    }

    @ViewBuilder
    private func tiles(_ s: StressSummary) -> some View {
        let dl = Format.speedParts(s.downloadAggregate?.medianMbps, settings: settings.settings)
        let ul = Format.speedParts(s.uploadAggregate?.medianMbps, settings: settings.settings)
        let loaded = [s.loadedLatencyMs(.download), s.loadedLatencyMs(.upload)].compactMap { $0 }.max()
        let cv = [s.downloadAggregate, s.uploadAggregate].compactMap { $0 }.filter { $0.values.count >= 2 }.compactMap(\.coefficientOfVariation).max()
        let large = s.downloadAggregate?.largeVariance == true || s.uploadAggregate?.largeVariance == true
        MetricTile(title: "持續下載", value: dl.value, unit: dl.unit, caption: "跨節點中位數", symbol: "arrow.down.circle", tint: Theme.download)
        MetricTile(title: "持續上傳", value: ul.value, unit: ul.unit, caption: "跨節點中位數", symbol: "arrow.up.circle", tint: Theme.upload)
        MetricTile(title: "下載穩定度", value: Format.number(s.stability(.download), digits: 0), unit: "%",
                   caption: Self.stabilityCaption(s.stabilityUnavailableReason(.download)), symbol: "waveform.path", tint: Theme.download)
        MetricTile(title: "上傳穩定度", value: Format.number(s.stability(.upload), digits: 0), unit: "%",
                   caption: Self.stabilityCaption(s.stabilityUnavailableReason(.upload)), symbol: "waveform.path", tint: Theme.upload)
        MetricTile(title: "閒置 Ping", value: Format.number(s.preLoadLatency?.rtt?.median, digits: 0), unit: "ms", symbol: "timer", tint: Theme.latency)
        MetricTile(title: "負載 Ping", value: Format.number(loaded, digits: 0), unit: "ms", caption: "下載 / 上傳較高者", symbol: "timer", tint: Theme.latency)
        MetricTile(title: "抖動", value: Format.number(s.preLoadLatency?.rtt?.jitter, digits: 1), unit: "ms", symbol: "chart.line.uptrend.xyaxis", tint: Theme.latency)
        MetricTile(title: "已確認封包遺失", value: Format.number(s.lossConfirmation.confirmedLossPercent, digits: 2), unit: "%",
                   caption: "\(s.lossConfirmation.validControlCount) 個對照探測中位數", symbol: "checkmark.shield", tint: Theme.good)
        MetricTile(title: "僅壓力 ICMP 遺失", value: Format.number(s.lossConfirmation.stressLossPercent, digits: 2), unit: "%",
                   caption: s.lossConfirmation.verdict == .possibleICMPRateLimiting ? "可能為 ICMP 限速" : "50 pps 壓力探測",
                   symbol: "bolt.badge.clock", tint: Theme.warning)
        MetricTile(title: "Bufferbloat", value: Format.number(s.bufferbloatMs, digits: 0), unit: "ms",
                   caption: s.bufferbloatMs == nil ? "無有效負載（insufficientLoad）" : "負載 − 閒置（佇列位置未知）",
                   symbol: "tray.full", tint: Theme.warning)
        MetricTile(title: "跨節點一致性", value: cv.map { large ? "差異大" : ($0 < 0.2 ? "一致" : "尚可") } ?? Format.dash,
                   caption: cv.map { "CV \(Format.number($0, digits: 2))" }, symbol: "square.stack.3d.up", tint: large ? Theme.critical : Theme.accent)
        MetricTile(title: "壓力分數", value: Format.score(s.score), unit: "/100", symbol: "flame", tint: Theme.critical)
        MetricTile(title: "總時間", value: StressProgressHeader.mmss(s.actualSeconds), caption: "設定 \(StressProgressHeader.mmss(s.configuredSeconds))",
                   symbol: "clock", tint: Theme.info)
        MetricTile(title: "總流量", value: Format.bytes(s.totalBytes), caption: "↓ \(Format.bytes(s.totalDownloadBytes)) ↑ \(Format.bytes(s.totalUploadBytes))",
                   symbol: "externaldrive", tint: Theme.info)
    }

    static func stabilityCaption(_ reason: String?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case "measurementSamplingArtifact": return "取樣批次化，無法可靠計算"
        case "noValidTransfer": return "沒有有效傳輸"
        default: return "資料不足"
        }
    }

    private func buildExports() {
        let r = result
        let includeLocation = settings.settings.includeLocationInExports
        let analysis = RawDataExporter.analysis(for: r, baselines: app.baselines(excluding: [r.id]))
        aiURL = try? ExportService.exportRawData(r, analysis: analysis, asJSON: false, includeLocation: includeLocation, privacy: .aiSafe)
        engineerURL = try? ExportService.exportRawData(r, analysis: analysis, asJSON: true, includeLocation: includeLocation,
                                                       privacy: .engineer(includeIPs: engineerIPs))
    }
}

/// Full technical data: per-node, per-round, phases, loss probes, recovery, plus the standard sections.
struct StressTechnicalView: View {
    let result: TestResult
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let s = result.stress {
                    section("實際流量與時間") {
                        KeyValueRow(key: "下載", value: Format.bytes(s.totalDownloadBytes))
                        KeyValueRow(key: "上傳", value: Format.bytes(s.totalUploadBytes))
                        KeyValueRow(key: "合計", value: Format.bytes(s.totalBytes))
                        KeyValueRow(key: "實際時間 / 設定", value: "\(StressProgressHeader.mmss(s.actualSeconds)) / \(StressProgressHeader.mmss(s.configuredSeconds))")
                        ForEach(s.phaseDurations, id: \.kind) { p in KeyValueRow(key: p.kind.title, value: String(format: "%.1f 秒", p.seconds)) }
                    }
                    section("節點健康檢查") {
                        ForEach(s.nodes) { n in
                            KeyValueRow(key: "\(n.name)（\(n.isThroughputCapable ? "吞吐量" : "僅延遲")）",
                                        value: n.healthy == true ? "正常 \(Format.ms(n.healthLatencyMs))" : "略過：\(n.healthDetail ?? "無回應")",
                                        valueColor: n.healthy == true ? Theme.textPrimary : Theme.warning)
                        }
                    }
                    section("各節點 · 各輪") {
                        ForEach(s.transfers) { t in
                            let name = s.nodes.first { $0.id == t.nodeID }?.name ?? t.nodeID
                            KeyValueRow(key: "\(name) 第 \(t.round) 輪 \(t.direction == .download ? "↓" : "↑")\((t.attempt ?? 1) > 1 ? "（重試）" : "")（\(t.method)）",
                                        value: t.isValid
                                            ? "\(Format.speed(t.rateMbps, settings: settings.settings)) · 負載 \(t.loadValid ? Format.ms(t.loadedLatency?.rtt?.median) : "無效負載")"
                                            : "無效：\(t.validity?.reason?.rawValue ?? "endpointFailure")（\(Format.bytes(t.bytes))）",
                                        valueColor: t.isValid ? Theme.textPrimary : Theme.warning)
                        }
                    }
                    ForEach([s.downloadAggregate, s.uploadAggregate].compactMap { $0 }, id: \.direction) { a in
                        section("跨業者彙整（\(a.direction == .download ? "下載" : "上傳")）") {
                            KeyValueRow(key: "平均 / 中位數", value: "\(Format.number(a.meanMbps, digits: 1)) / \(Format.number(a.medianMbps, digits: 1)) Mbps")
                            KeyValueRow(key: "最小 / 最大", value: "\(Format.number(a.minMbps, digits: 1)) / \(Format.number(a.maxMbps, digits: 1)) Mbps")
                            KeyValueRow(key: "P10 / P95", value: "\(Format.number(a.p10Mbps, digits: 1)) / \(Format.number(a.p95Mbps, digits: 1)) Mbps")
                            KeyValueRow(key: "節點間變異數 / CV", value: "\(Format.number(a.variance, digits: 1)) / \(Format.number(a.coefficientOfVariation, digits: 2))")
                            if a.largeVariance {
                                Text("Large cross-provider throughput variance：不同業者節點速度差異大，可能是路由 / 互連或個別節點容量，而非你的網路上限。")
                                    .font(.caption2).foregroundStyle(Theme.warning)
                            }
                        }
                    }
                    section("封包遺失（壓力 vs 對照）") {
                        ForEach([s.stressProbe].compactMap { $0 } + s.controlProbes) { p in
                            KeyValueRow(key: "\(p.name) · \(Int(p.packetsPerSecond)) pps", value: "\(Format.percent(p.lossPercent, digits: 2))（\(p.sent) 個）")
                        }
                        KeyValueRow(key: "判定", value: s.lossConfirmation.verdict.displayName)
                        Text("只有多個獨立探測同時遺失才視為真實遺失；僅 50 pps ICMP 遺失多半是節點對 ICMP 限速。").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    section("負載前 / 負載中 / 負載後延遲") {
                        KeyValueRow(key: "負載前", value: Format.ms(s.preLoadLatency?.rtt?.median, digits: 1))
                        KeyValueRow(key: "下載中 / 上傳中", value: "\(Format.ms(s.loadedLatencyMs(.download))) / \(Format.ms(s.loadedLatencyMs(.upload)))")
                        ForEach(Array(s.postLoadLatency.enumerated()), id: \.offset) { i, p in
                            KeyValueRow(key: "第 \(i + 1) 輪負載後", value: Format.ms(p.rtt?.median, digits: 1))
                        }
                        KeyValueRow(key: "恢復差值", value: Format.ms(s.recoveryDeltaMs, digits: 1))
                        KeyValueRow(key: "第 1 輪 → 最後一輪下載變化", value: s.throughputDegradationPercent.map { String(format: "%.0f%%", -$0) } ?? Format.dash)
                    }
                }
                TechnicalDetailsView(result: result)
                RawDataCard(result: result)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("完整技術資料")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
