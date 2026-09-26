import SwiftUI
import Charts
import ChaiNetCore
import ChaiNetEngines

/// Live progress: phase stepper, current speed with average / peak, and a real-time chart.
struct LiveRunView: View {
    let vm: RunViewModel
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 14) {
            PhaseStrip(current: vm.phase, completed: vm.completedPhases, planned: plannedPhases)
            if let direction = vm.activeDirection ?? lastDirection {
                ThroughputLivePanel(vm: vm, direction: direction)
            } else if vm.phase == .idleLatency || vm.phase == .packetLoss || vm.phase == .monitoring {
                let phase = vm.phase ?? .idleLatency
                LatencyLivePanel(samples: vm.latencySamples[phase] ?? [],
                                 title: vm.stressProgress.map { $0.kind.isLoadPhase ? phase.displayName : $0.kind.title } ?? phase.displayName,
                                 status: vm.notes[phase]?.last?.text)
            } else {
                PhaseActivityPanel(vm: vm, phase: vm.phase ?? .preparing)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            if let server = vm.server {
                Label("\(server.name) · \(server.location)", systemImage: "server.rack")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: vm.phase)
    }

    private var lastDirection: TransferDirection? {
        if vm.phase == .upload { return .upload }
        return nil
    }

    private var plannedPhases: [TestPhase] {
        guard let items = vm.configuration?.items else { return [] }
        var phases: [TestPhase] = []
        if !items.isDisjoint(with: [.ping, .jitter, .download, .upload, .bufferbloat]) { phases.append(.idleLatency) }
        if !items.isDisjoint(with: [.packetLoss, .burstLoss, .latencySpikes, .jitter]) { phases.append(.packetLoss) }
        if items.contains(.download) || items.contains(.bufferbloat) { phases.append(.download) }
        if items.contains(.upload) || items.contains(.bufferbloat) { phases.append(.upload) }
        if items.contains(.continuousPing) || items.contains(.dropMonitor) { phases.append(.monitoring) }
        if items.contains(.dns) { phases.append(.dns) }
        if !items.isDisjoint(with: [.http, .tls, .quic]) { phases.append(.protocols) }
        if items.contains(.ipFamilies) { phases.append(.ipFamilies) }
        if items.contains(.crossValidation) { phases.append(.crossValidation) }
        if items.contains(.interfaceCompare) { phases.append(.interfaceCompare) }
        if items.contains(.mtu) { phases.append(.mtu) }
        if items.contains(.traceroute) { phases.append(.traceroute) }
        return phases
    }
}

private struct PhaseStrip: View {
    let current: TestPhase?
    let completed: [TestPhase]
    let planned: [TestPhase]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(planned, id: \.self) { phase in
                    let done = completed.contains(phase)
                    let active = phase == current
                    HStack(spacing: 4) {
                        if done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                        } else if active {
                            PulsingDot(color: Theme.accent).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "circle").foregroundStyle(Theme.textSecondary)
                        }
                        Text(phase.displayName)
                    }
                    .font(.caption.weight(active ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(active ? Theme.accent.opacity(0.15) : Theme.surfaceRaised, in: Capsule())
                    .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
                }
            }
        }
        .animation(.snappy, value: current)
    }
}

private struct ThroughputLivePanel: View {
    let vm: RunViewModel
    let direction: TransferDirection
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = settings.settings
        let samples = vm.samples(direction)
        let summary = vm.displaySummary[direction]
        let elapsed = samples.last?.offset ?? 0
        let color = direction == .download ? Theme.download : Theme.upload
        let loaded = LatencyStatistics.compute(from: Array((vm.latencySamples[direction == .download ? .download : .upload] ?? []).suffix(30)))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(direction == .download ? "下載" : "上傳", systemImage: direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.headline).foregroundStyle(color)
                Spacer()
                Text(String(format: "%.1f 秒", elapsed)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            // Readout glides between 0.5 s updates at display refresh rate (no blur / rolling digits).
            TimelineView(.animation) { context in
                let parts = Format.speedParts(vm.animatedMbps(direction, at: context.date), settings: s)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.value)
                        .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(parts.unit).font(.title3.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    if let secondary = Format.secondarySpeed(vm.displayMbps[direction], settings: s) {
                        Text(secondary).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
                .transaction { $0.animation = nil }
            }
            LiveThroughputChart(samples: samples, lastSampleAt: vm.lastSampleAt[direction], unit: s.primarySpeedUnit, color: color,
                                style: s.chartStyle, averageMbps: summary?.averageMbps,
                                minimumBinSeconds: Double(SpeedCalculator.batching(samples).windowSamples) * 0.1, height: 180,
                                head: vm.displayMbps[direction])
            let ready = elapsed >= 2 && (summary?.shortWindowReliable ?? true)
            HStack(alignment: .top, spacing: 12) {
                LiveStat(title: "平均", value: Format.speed(summary?.averageMbps, settings: s))
                LiveStat(title: "中位數", value: ready ? Format.speed(summary?.medianMbps, settings: s) : "計算中")
                LiveStat(title: "負載延遲", value: loaded.sent > 0 ? Format.ms(loaded.rtt?.median) : Format.dash)
                LiveStat(title: "已傳輸", value: samples.last.map { Format.bytes($0.cumulativeBytes) } ?? Format.dash)
            }
            Text("中位數：一半時間比它快、一半比它慢，不受瞬間尖峰影響。負載延遲：傳輸同時量測的 Ping，明顯升高代表網路在排隊。")
                .font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
        .cardStyle()
    }
}

private struct LiveStat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.textSecondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LatencyLivePanel: View {
    let samples: [LatencySample]
    let title: String
    /// Latest status line of the phase (what is measured now / time left).
    var status: String? = nil

    var body: some View {
        let stats = LatencyStatistics.compute(from: samples)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(title, systemImage: "dot.radiowaves.left.and.right").font(.headline).foregroundStyle(Theme.latency)
                Spacer()
                Text("\(stats.sent) 個探測").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transaction { $0.animation = nil }
            }
            HStack(alignment: .top, spacing: 12) {
                LiveStat(title: "中位數", value: Format.ms(stats.rtt?.median))
                LiveStat(title: "P95", value: Format.ms(stats.rtt?.p95))
                LiveStat(title: "抖動", value: Format.ms(stats.rtt?.jitter, digits: 1))
                LiveStat(title: "遺失", value: stats.sent > 0 ? Format.percent(stats.loss.lossPercent) : Format.dash)
            }
            LatencyChart(samples: samples.sorted { $0.sequence < $1.sequence }, height: 140)
                .animation(.easeOut(duration: 0.25), value: samples.count)
            Text("中位數：平常的延遲。P95：95% 的 Ping 低於此值，反映偶發卡頓。抖動：延遲的變動，影響通話與遊戲。")
                .font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
        .cardStyle()
    }
}

/// Later phases (DNS, HTTP / TLS / QUIC, IPv4 / IPv6, cross-validation, MTU, route…): what is
/// being measured right now, live series / values, and a short Chinese log — never a bare spinner.
private struct PhaseActivityPanel: View {
    let vm: RunViewModel
    let phase: TestPhase

    var body: some View {
        let series = vm.liveSeriesOrder[phase] ?? []
        let values = vm.liveValues[phase] ?? []
        let notes = vm.notes[phase] ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(phase.displayName, systemImage: Self.symbol(phase)).font(.headline).foregroundStyle(Theme.accent)
                PulsingDot(color: Theme.accent)
                Spacer()
                if let start = vm.phaseStartedAt {
                    TimelineView(.periodic(from: start, by: 0.1)) { context in
                        Text(String(format: "%.1f 秒", context.date.timeIntervalSince(start)))
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Text(Self.explanation(phase)).font(.footnote).foregroundStyle(Theme.textSecondary)
            if !series.isEmpty {
                SeriesLiveChart(phase: phase, order: series, series: vm.liveSeries[phase] ?? [:])
            }
            if !values.isEmpty {
                LiveBarList(values: values)
            }
            if phase == .traceroute, !vm.traceHops.isEmpty {
                HopList(hops: vm.traceHops)
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes) { n in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: n.id == notes.last?.id ? "chevron.right.circle.fill" : "checkmark.circle")
                                .font(.caption2).foregroundStyle(n.id == notes.last?.id ? Theme.accent : Theme.textSecondary)
                            Text(n.text).font(.caption).foregroundStyle(n.id == notes.last?.id ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
                .animation(.spring(duration: 0.35), value: notes.map(\.id))
            } else if series.isEmpty && values.isEmpty && (phase != .traceroute || vm.traceHops.isEmpty) {
                ShimmerBar()
            }
        }
        .cardStyle()
    }

    static func symbol(_ p: TestPhase) -> String {
        switch p {
        case .dns: "globe"
        case .protocols: "lock.shield"
        case .ipFamilies: "point.3.connected.trianglepath.dotted"
        case .crossValidation: "checkmark.seal"
        case .interfaceCompare: "wifi"
        case .mtu: "shippingbox"
        case .traceroute: "map"
        case .multiServer: "server.rack"
        case .selectingServer: "scope"
        case .analyzing: "brain"
        default: "sparkles"
        }
    }

    static func explanation(_ p: TestPhase) -> String {
        switch p {
        case .preparing: "讀取網路狀態（介面、IP、VPN、行動網路資訊），準備測試。"
        case .selectingServer: "對候選伺服器量測延遲與健康狀態，選出最適合的測速伺服器。"
        case .dns: "比較系統 DNS 與公共 DNS（UDP / DoH）解析常用網域的速度與失敗率。"
        case .protocols: "拆解一次 HTTPS 連線的每一步耗時，並確認 HTTP/3、QUIC 是否可用。"
        case .ipFamilies: "分別用 IPv4、IPv6 連到同一伺服器，比較兩條路徑的延遲與穩定性。"
        case .crossValidation: "同時量測多個不同業者的端點，判斷異常只在單一伺服器還是普遍存在。"
        case .interfaceCompare: "經由 Wi‑Fi 與行動網路分別量測，比較兩個介面的品質。"
        case .mtu: "送出「禁止分段」的封包並逐步調整大小，找出路徑可通過的最大封包（MTU）。"
        case .traceroute: "逐跳追蹤封包經過的路由節點，觀察延遲在哪一段開始增加。"
        case .multiServer: "對其他伺服器重複測速，比較不同伺服器的結果。"
        case .analyzing: "彙整所有量測，計算分數並產生診斷。"
        default: "量測中…"
        }
    }
}

/// Live RTT lines, one per series (IPv4 / IPv6, endpoints, interfaces), with per-series stats.
private struct SeriesLiveChart: View {
    let phase: TestPhase
    let order: [String]
    let series: [String: [LatencySample]]

    static let palette: [Color] = [Theme.download, Theme.upload, Theme.latency, Theme.good, Theme.info, Theme.critical]

    private var chips: [FlowChips.Chip] {
        var out: [FlowChips.Chip] = []
        for (index, name) in order.enumerated() {
            let stats = LatencyStatistics.compute(from: series[name] ?? [])
            let median = stats.rtt.map { "\(Format.number($0.median, digits: 0)) ms" } ?? "無回應"
            let loss = stats.sent > 0 && stats.loss.lost > 0 ? " · 遺失 \(Format.percent(stats.loss.lossPercent, digits: 0))" : ""
            out.append(FlowChips.Chip(name: name, value: median + loss, color: Self.palette[index % Self.palette.count]))
        }
        return out
    }

    var body: some View {
        let total = series.values.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(Array(order.enumerated()), id: \.element) { index, name in
                    ForEach((series[name] ?? []).sorted { $0.sequence < $1.sequence }) { s in
                        if let rtt = s.rttMs {
                            LineMark(x: .value("序號", s.sequence), y: .value("ms", rtt), series: .value("序列", name))
                                .foregroundStyle(Self.palette[index % Self.palette.count])
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        } else {
                            PointMark(x: .value("序號", s.sequence), y: .value("ms", 0))
                                .foregroundStyle(Theme.critical).symbol(.cross)
                        }
                    }
                }
            }
            .chartYAxisLabel("ms")
            .chartLegend(.hidden)
            .frame(height: 130)
            .animation(.easeOut(duration: 0.25), value: total)
            FlowChips(items: chips)
        }
    }
}

private struct FlowChips: View {
    struct Chip: Identifiable {
        var name: String
        var value: String
        var color: Color
        var id: String { name }
    }
    let items: [Chip]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items) { chip in
                HStack(spacing: 6) {
                    Circle().fill(chip.color).frame(width: 7, height: 7)
                    Text(chip.name).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Text(chip.value).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                        .transaction { $0.animation = nil }
                }
            }
        }
    }
}

/// Horizontal bars (e.g. DNS resolver medians, connection-step timings) that grow in smoothly.
private struct LiveBarList: View {
    let values: [RunViewModel.LiveValue]

    var body: some View {
        let maxValue = max(values.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(values) { v in
                HStack(spacing: 8) {
                    Text(v.label).font(.caption).foregroundStyle(Theme.textSecondary).frame(width: 92, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        Capsule().fill(Theme.surfaceRaised)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.accent.gradient)
                                    .frame(width: max(4, geo.size.width * CGFloat(v.value / maxValue)))
                            }
                    }
                    .frame(height: 8)
                    Text("\(Format.number(v.value, digits: v.value < 10 ? 1 : 0)) \(v.unit)")
                        .font(.caption.weight(.semibold).monospacedDigit()).frame(width: 64, alignment: .trailing)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.15), value: values)
    }
}

private struct HopList: View {
    let hops: [TracerouteHop]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(hops.suffix(8)) { h in
                HStack(spacing: 8) {
                    Text("\(h.ttl)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary).frame(width: 22, alignment: .trailing)
                    Text(h.hostname ?? h.address ?? "* 無回應").font(.caption).lineLimit(1)
                    Spacer()
                    Text(h.bestMs.map { "\(Format.number($0, digits: 1)) ms" } ?? "—").font(.caption.monospacedDigit())
                        .foregroundStyle(h.bestMs == nil ? Theme.textSecondary : Theme.textPrimary)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: hops.count)
    }
}

/// Indeterminate progress without a spinner: a soft light sweeping across a track.
private struct ShimmerBar: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { geo in
                Capsule().fill(Theme.surfaceRaised)
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent, Theme.accent.opacity(0)],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: (geo.size.width * 1.35) * t - geo.size.width * 0.35)
                    }
                    .clipShape(Capsule())
            }
            .frame(height: 6)
        }
    }
}
