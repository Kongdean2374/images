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
    @State private var cellularConfirming = false
    /// Mobile-data safety caps in MB (nil = no limit). On cellular a 1.5 GB hard cap is
    /// preselected; choosing 「不限」 there is recorded as an explicit unlimited choice.
    @State private var hardCapMB: Int?
    @State private var downloadCapMB: Int?
    @State private var uploadCapMB: Int?
    @State private var capsInitialized = false

    private var dataLimits: StressDataLimits {
        let mb = StressDataLimits.megabyte
        let dl = downloadCapMB.map { Int64($0) * mb }, ul = uploadCapMB.map { Int64($0) * mb }
        if let hard = hardCapMB {
            let policy = app.onCellular && hard == 1_500 && dl == nil && ul == nil ? "cellularDefault" : "userConfigured"
            return .withHardCap(Int64(hard) * mb, downloadCap: dl, uploadCap: ul, policy: policy)
        }
        return StressDataLimits(downloadCapBytes: dl, uploadCapBytes: ul, explicitlyUnlimited: dl == nil && ul == nil ? true : nil)
            .effective(onCellular: app.onCellular)
    }

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
                        StressProgressHeader(vm: vm, estimated: vm.configuration?.stressPlan?.estimatedSeconds ?? plan.estimatedSeconds,
                                             limits: (vm.configuration?.stressDataLimits ?? .unlimited).effective(onCellular: vm.configuration?.onCellular ?? false))
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
        .onAppear {
            if vm == nil { vm = app.makeRunViewModel() }
            if !capsInitialized {
                capsInitialized = true
                if app.onCellular { hardCapMB = 1_500 }
            }
        }
        .onDisappear { vm?.stop() }
    }

    // MARK: Setup

    @ViewBuilder
    private func setup(_ vm: RunViewModel) -> some View {
        let plan = plan
        let network = app.currentNetwork
        let cls = network.map(NetworkClass.init(snapshot:)) ?? .unknown
        let rates = StressTestPlan.assumedMbps(history: app.history.results(limit: 200), networkClass: cls)
        let traffic = plan.trafficEstimate(downloadMbps: rates.download, uploadMbps: rates.upload, networkClass: cls)

        VStack(alignment: .leading, spacing: 8) {
            Label("最大強度 · 正常網速 + 壓力階段", systemImage: "flame.fill").font(.headline).foregroundStyle(Theme.critical)
            Text("先量一輪正常網速（Cloudflare HTTP ×16，M-Lab NDT7 驗證）作為主要結果；再進行連線數階梯（找飽和點）、持續下載 / 上傳、上下行同時滿載、突發負載、多目的地同時下載，每段重負載後量恢復。全程以同一固定對照探測量延遲，另含 50 pps / 5 pps 封包遺失、DNS / 協定、IPv4 / IPv6、路由與 MTU。")
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
            let reason = plan.durationAdjustmentReason(configuredSeconds: totalSeconds)
            if reason != "none" {
                Text("設定 \(StressProgressHeader.mmss(totalSeconds))，實際預估 \(StressProgressHeader.mmss(plan.estimatedSeconds))：\(Self.durationReasonText(reason))")
                    .font(.caption2).foregroundStyle(Theme.warning)
            }
            Text("正常網速每個節點下載 / 上傳各 \(Int(plan.transferSeconds.rounded())) 秒（M-Lab NDT7 依協定上限 10 秒）；超過 300 秒的時間優先分配給持續負載、全雙工與最終恢復。壓力結果與正常網速分開呈現。")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()

        VStack(alignment: .leading, spacing: 6) {
            Text("預估流量").font(.headline)
            KeyValueRow(key: "下載", value: Format.bytes(traffic.downloadBytes))
            KeyValueRow(key: "上傳", value: Format.bytes(traffic.uploadBytes))
            KeyValueRow(key: "合計", value: Format.bytes(traffic.totalBytes), valueColor: Theme.critical)
            KeyValueRow(key: "預估範圍", value: "\(Format.bytes(traffic.lowBytes)) – \(Format.bytes(traffic.highBytes))", valueColor: Theme.critical)
            if let cd = traffic.ceilingDownloadMbps, let cu = traffic.ceilingUploadMbps {
                Text("範圍上限以此網路類型的高速情況（下載 \(Format.number(cd, digits: 0)) / 上傳 \(Format.number(cu, digits: 0)) Mbps）估算；測試中會依實測速度更新預估。")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Text(rates.fromHistory
                 ? "依此網路類型最近結果（下載 \(Format.number(rates.download, digits: 0)) / 上傳 \(Format.number(rates.upload, digits: 0)) Mbps）估算；實際流量依網路速度而定。"
                 : "尚無此網路類型的紀錄，以典型速度（下載 \(Format.number(rates.download, digits: 0)) / 上傳 \(Format.number(rates.upload, digits: 0)) Mbps）估算；實際可能更多。")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()

        dataLimitCard(traffic: traffic)

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
                Button("我了解，開始", role: .destructive) {
                    if app.onCellular { cellularConfirming = true } else { start(vm, plan: plan, traffic: traffic) }
                }
            } message: {
                Text(StressTestPlan.confirmationWarning + "\n預估流量 \(Format.bytes(traffic.lowBytes)) – \(Format.bytes(traffic.highBytes))，約 \(StressProgressHeader.mmss(plan.estimatedSeconds))。")
            }
            .alert("正在使用行動數據", isPresented: $cellularConfirming) {
                Button("取消", role: .cancel) {}
                Button("確認使用行動數據", role: .destructive) { start(vm, plan: plan, traffic: traffic) }
            } message: {
                Text("極限壓力測試在行動網路下預估使用 \(Format.bytes(traffic.lowBytes)) – \(Format.bytes(traffic.highBytes))，可能產生額外費用或觸發降速。"
                     + (hardCapMB.map { "\n硬上限 \(Self.mbText($0))：達到後自動停止吞吐量階段，其餘低流量診斷照常完成。" } ?? "\n您已選擇「不限」：不會自動停止。"))
            }
        Text("測試期間請保持 App 在前景；進入背景會停止並保留已完成的部分。").font(.caption2).foregroundStyle(Theme.textSecondary)
    }

    private func start(_ vm: RunViewModel, plan: StressTestPlan, traffic: TrafficEstimate) {
        var s = settings.settings
        s.trafficUsage = .unlimited
        var config = TestRunConfiguration(kind: .extremeStressTest, items: [], candidateServers: settings.allServers,
                                          settings: s, onCellular: app.onCellular)
        config.stressPlan = plan
        config.stressWarnings = app.currentNetwork.map(StressTestPlan.warnings(for:)) ?? []
        config.stressDataLimits = dataLimits
        config.stressTrafficEstimate = traffic
        vm.start(config)
    }

    @ViewBuilder
    private func dataLimitCard(traffic: TrafficEstimate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("流量上限").font(.headline)
                Spacer()
                if app.onCellular {
                    Label("行動數據", systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            if app.onCellular {
                Text("預估將使用約 \(Format.bytes(traffic.lowBytes)) – \(Format.bytes(traffic.highBytes)) 行動數據")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.critical)
            }
            capPicker("總量硬上限", selection: $hardCapMB)
            capPicker("下載上限", selection: $downloadCapMB)
            capPicker("上傳上限", selection: $uploadCapMB)
            let limits = dataLimits
            if let w = limits.warningBytes {
                KeyValueRow(key: "警告門檻", value: Format.bytes(w), valueColor: Theme.warning)
            }
            if let w = limits.softWarningBytes {
                KeyValueRow(key: "強烈警告", value: Format.bytes(w), valueColor: Theme.critical)
            }
            if app.onCellular && hardCapMB == nil {
                Text("已明確選擇「不限」：行動網路下將不會自動停止吞吐量階段。").font(.caption2).foregroundStyle(Theme.critical)
            }
            if let h = limits.hardCapBytes, h < traffic.highBytes {
                Text("硬上限低於預估流量上緣：部分吞吐量階段可能被略過，結果會標示 dataCapReached。")
                    .font(.caption2).foregroundStyle(Theme.warning)
            }
            Text("達到上限時自動停止吞吐量（下載 / 上傳）階段；延遲、遺失、DNS、協定、IP 版本、路由與 MTU 等低流量診斷仍會完成。")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }

    static func durationReasonText(_ reason: String) -> String {
        switch reason {
        case "minimumRequiredDiagnosticPhases": return "延遲、遺失、DNS、路由等診斷階段有最低時間，且吞吐量至少保留 40%，所以比設定時間長。"
        case "minimumTransferSeconds": return "每次傳輸至少 6 秒（多節點 × 雙向 × 多輪），所以比設定時間長。"
        case "requestedBelowMinimum": return "最短測試時間為 60 秒。"
        case "ndt7ProtocolCap": return "M-Lab NDT7 依協定最長 10 秒，所以比設定時間短。"
        default: return reason
        }
    }

    static func mbText(_ mb: Int) -> String { mb >= 1_000 ? "\(Format.number(Double(mb) / 1_000, digits: mb % 1_000 == 0 ? 0 : 1)) GB" : "\(mb) MB" }

    private func capPicker(_ title: String, selection: Binding<Int?>) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Picker(title, selection: selection) {
                Text("不限").tag(Int?.none)
                ForEach(StressDataLimits.capPresetsMB, id: \.self) { Text(Self.mbText($0)).tag(Int?.some($0)) }
            }
            .pickerStyle(.menu)
        }
    }
}

// MARK: - Progress

private struct StressProgressHeader: View {
    let vm: RunViewModel
    let estimated: Double
    let limits: StressDataLimits

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = vm.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(Self.mmss(elapsed)) / 約 \(Self.mmss(estimated))").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                }
                if let sub = subtitle {
                    Text(sub).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ProgressView(value: min(elapsed / max(estimated, 1), 1)).tint(Theme.critical)
                if let p = vm.stressProgress {
                    Text("階段 \(p.phaseIndex) / \(p.phaseCount) · 已用流量 ↓ \(Format.bytes(p.downloadBytes)) ↑ \(Format.bytes(p.uploadBytes))")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    if let projected = p.projectedBytes {
                        let over = limits.hardCapBytes.map { projected > $0 } ?? false
                        Text("依實測速度預估總流量：約 \(Format.bytes(projected))" + (over ? "（將超過硬上限，達上限時自動停止吞吐量階段）" : ""))
                            .font(.caption2.monospacedDigit()).foregroundStyle(over ? Theme.warning : Theme.textSecondary)
                    }
                    usage(down: p.downloadBytes, up: p.uploadBytes)
                }
            }
            .cardStyle()
        }
    }

    @ViewBuilder
    private func usage(down: Int64, up: Int64) -> some View {
        let used = down + up
        if let cap = limits.hardCapBytes {
            let reached = used >= cap
            let warn = limits.warningBytes.map { used >= $0 } ?? false
            let soft = limits.softWarningBytes.map { used >= $0 } ?? false
            let color = reached || soft ? Theme.critical : (warn ? Theme.warning : Theme.textSecondary)
            ProgressView(value: min(Double(used) / Double(max(cap, 1)), 1)).tint(reached ? Theme.critical : (warn ? Theme.warning : Theme.accent))
            Text(reached ? "已達流量硬上限 \(Format.bytes(cap))：吞吐量階段已停止，繼續完成低流量診斷"
                         : "Data used：\(Format.bytes(used)) / 上限 \(Format.bytes(cap))\(soft ? "（已超過強烈警告門檻）" : (warn ? "（已超過警告門檻）" : ""))")
                .font(.caption2.monospacedDigit()).foregroundStyle(color)
        } else {
            Text("Data used：\(Format.bytes(used))（未設定上限）").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
        }
        if let d = limits.downloadCapBytes {
            Text("下載 \(Format.bytes(down)) / \(Format.bytes(d))").font(.caption2.monospacedDigit())
                .foregroundStyle(down >= d ? Theme.critical : Theme.textSecondary)
        }
        if let u = limits.uploadCapBytes {
            Text("上傳 \(Format.bytes(up)) / \(Format.bytes(u))").font(.caption2.monospacedDigit())
                .foregroundStyle(up >= u ? Theme.critical : Theme.textSecondary)
        }
    }

    /// Phase name on its own line (wraps instead of being cut off); round / node below it.
    private var title: String { vm.stressProgress?.kind.title ?? "極限壓力測試進行中" }

    private var subtitle: String? {
        guard let p = vm.stressProgress else { return nil }
        let parts = [p.round.map { "第 \($0) 輪" }, p.nodeName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

                if let load = result.stressLoad {
                    StressLoadSummaryCard(report: load, standardDownloadMbps: s.headlineMbps(.download), standardUploadMbps: s.headlineMbps(.upload))
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    tiles(s)
                    if let load = result.stressLoad { StressLoadTiles(report: load) }
                    diagnosticTiles
                }

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
        let dl = Format.speedParts(s.headlineMbps(.download), settings: settings.settings)
        let ul = Format.speedParts(s.headlineMbps(.upload), settings: settings.settings)
        let comparable = [s.downloadAggregate, s.uploadAggregate].compactMap { $0 }.allSatisfy(\.comparable)
        let loaded = [s.loadedLatencyMs(.download), s.loadedLatencyMs(.upload)].compactMap { $0 }.max()
        let cv = [s.downloadAggregate, s.uploadAggregate].compactMap { $0 }.filter { $0.values.count >= 2 && $0.comparable }.compactMap(\.coefficientOfVariation).max()
        let large = s.downloadAggregate?.largeVariance == true || s.uploadAggregate?.largeVariance == true
        MetricTile(title: "正常下載", value: dl.value, unit: dl.unit, caption: Self.headlineCaption(s, .download), symbol: "arrow.down.circle", tint: Theme.download)
        MetricTile(title: "正常上傳", value: ul.value, unit: ul.unit, caption: Self.headlineCaption(s, .upload), symbol: "arrow.up.circle", tint: Theme.upload)
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
        let limitedBloat = [s.bufferbloatComparison(.download), s.bufferbloatComparison(.upload)].compactMap { $0 }.contains { $0.quality == .limited }
        MetricTile(title: "Bufferbloat", value: Format.number(s.bufferbloatMs, digits: 0), unit: "ms",
                   caption: s.bufferbloatMs == nil ? "無有效負載（insufficientLoad）"
                       : (limitedBloat ? "比較基準有限（僅供參考）" : "獨立對照探測 · 負載 − 閒置"),
                   symbol: "tray.full", tint: Theme.warning)
        if comparable {
            MetricTile(title: "跨節點一致性", value: cv.map { large ? "差異大" : ($0 < 0.2 ? "一致" : "尚可") } ?? Format.dash,
                       caption: cv.map { "CV \(Format.number($0, digits: 2))" }, symbol: "square.stack.3d.up", tint: large ? Theme.critical : Theme.accent)
        } else {
            let range = s.downloadAggregate.map { "\(Format.number($0.minMbps, digits: 0))–\(Format.number($0.maxMbps, digits: 0))" }
            MetricTile(title: "跨節點觀察範圍", value: range ?? Format.dash, unit: "Mbps",
                       caption: "方法不同（HTTP ×16 / NDT7 ×1），不比較一致性", symbol: "square.stack.3d.up", tint: Theme.accent)
        }
        MetricTile(title: "壓力分數", value: Format.score(s.score), unit: "/100", symbol: "flame", tint: Theme.critical)
        MetricTile(title: "總時間", value: StressProgressHeader.mmss(s.actualSeconds), caption: "設定 \(StressProgressHeader.mmss(s.configuredSeconds))",
                   symbol: "clock", tint: Theme.info)
        MetricTile(title: "總流量", value: Format.bytes(s.totalBytes), caption: "↓ \(Format.bytes(s.totalDownloadBytes)) ↑ \(Format.bytes(s.totalUploadBytes))",
                   symbol: "externaldrive", tint: Theme.info)
    }

    /// IPv4 / IPv6, DNS, QUIC and MTU at a glance (details in the technical view).
    @ViewBuilder
    private var diagnosticTiles: some View {
        let r = result
        if let f = r.ipFamilyComparison {
            MetricTile(title: "IPv4 / IPv6", value: "\(Format.number(f.ipv4?.rtt?.median, digits: 0)) / \(Format.number(f.ipv6?.rtt?.median, digits: 0))", unit: "ms",
                       caption: f.ipv6 == nil ? (f.ipv6Error.map { "IPv6：\($0)" } ?? "IPv6 不可用") : f.target, symbol: "number", tint: Theme.info)
        }
        if let best = r.dns?.ranked.first {
            MetricTile(title: "DNS", value: Format.number(best.statistics.rtt?.median, digits: 0), unit: "ms", caption: "最快：\(best.resolver.name)",
                       symbol: "globe", tint: Theme.info)
        }
        if let p = r.protocolProbe {
            MetricTile(title: "QUIC 交握", value: Format.availability(p.quicHandshakeMs) { Format.number($0, digits: 0) }, unit: "",
                       caption: p.host, symbol: "bolt.horizontal.circle", tint: Theme.info)
        }
        if let m = r.mtu {
            MetricTile(title: "路徑 MTU", value: m.pathMTU.map(String.init) ?? Format.dash, unit: "bytes", caption: "IPv4 → \(m.target)",
                       symbol: "ruler", tint: Theme.info)
        }
    }

    /// Headline scope: a cross-provider median only when every node used the same method; otherwise
    /// the primary speed test alone (validation providers are listed in the technical view).
    static func headlineCaption(_ s: StressSummary, _ direction: TransferDirection) -> String {
        guard s.headlineScope(direction) == "primary_method" else { return "跨節點中位數" }
        let name = s.plan.throughputNodes.first { $0.id == s.primaryNodeID }?.name ?? "主要節點"
        return "主要測速：\(name)"
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
                    if let load = result.stressLoad {
                        StressLoadTechnicalSections(report: load)
                    }
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
                            KeyValueRow(key: "主要結果", value: "\(Format.number(s.headlineMbps(a.direction), digits: 1)) Mbps（\(s.headlineScope(a.direction))）")
                            ForEach(a.values, id: \.nodeID) { v in
                                KeyValueRow(key: "\(v.name)\(v.nodeID == s.primaryNodeID ? "（主要）" : "（驗證）")",
                                            value: "\(Format.number(v.mbps, digits: 1)) Mbps · \(v.transportProtocol ?? "?") ×\(v.streamCount.map(String.init) ?? "?")")
                            }
                            KeyValueRow(key: "最小 / 最大", value: "\(Format.number(a.minMbps, digits: 1)) / \(Format.number(a.maxMbps, digits: 1)) Mbps")
                            if a.comparable {
                                KeyValueRow(key: "平均 / 中位數", value: "\(Format.number(a.meanMbps, digits: 1)) / \(Format.number(a.medianMbps, digits: 1)) Mbps")
                                KeyValueRow(key: "P10 / P95", value: "\(Format.number(a.p10Mbps, digits: 1)) / \(Format.number(a.p95Mbps, digits: 1)) Mbps")
                                KeyValueRow(key: "節點間變異數 / CV", value: "\(Format.number(a.variance, digits: 1)) / \(Format.number(a.coefficientOfVariation, digits: 2))")
                            } else {
                                Text("量測方法不同（串流數 / 協定不同），僅列出觀察範圍，不計算跨業者平均、變異與一致性。")
                                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            if a.largeVariance && a.comparable {
                                Text("Large cross-provider throughput variance：不同業者節點速度差異大，可能是路由 / 互連或個別節點容量，而非你的網路上限。")
                                    .font(.caption2).foregroundStyle(Theme.warning)
                            }
                        }
                    }
                    let comparisons = [s.bufferbloatComparison(.download), s.bufferbloatComparison(.upload)].compactMap { $0 }
                    if !comparisons.isEmpty {
                        section("Bufferbloat 比較基準") {
                            ForEach(comparisons, id: \.direction) { c in
                                KeyValueRow(key: c.direction == .download ? "下載" : "上傳",
                                            value: "閒置 \(Format.ms(c.idleMedianMs)) → 負載 \(Format.ms(c.loadedMedianMs))（+\(Format.number(c.increaseMs, digits: 0)) ms）")
                                KeyValueRow(key: "探測", value: "\(c.probe.method) · \(c.probe.protocolName) · \(c.probe.ipFamily) · 樣本 \(c.idleSampleCount)/\(c.loadedSampleCount)")
                                KeyValueRow(key: "比較品質", value: c.quality == .full ? "full（同方法、同目標、目標未負載）" : "limited（僅供參考）",
                                            valueColor: c.quality == .full ? Theme.textPrimary : Theme.warning)
                            }
                        }
                    }
                    if let limits = s.dataLimits {
                        section("流量上限") {
                            KeyValueRow(key: "政策", value: limits.policy ?? "userConfigured")
                            KeyValueRow(key: "硬上限", value: limits.hardCapBytes.map(Format.bytes) ?? "不限")
                            KeyValueRow(key: "下載 / 上傳上限", value: "\(limits.downloadCapBytes.map(Format.bytes) ?? "不限") / \(limits.uploadCapBytes.map(Format.bytes) ?? "不限")")
                            KeyValueRow(key: "是否達到上限", value: s.dataCapReached == true ? "是（吞吐量階段已停止）" : "否",
                                        valueColor: s.dataCapReached == true ? Theme.warning : Theme.textPrimary)
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
