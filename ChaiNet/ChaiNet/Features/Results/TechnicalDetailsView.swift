import SwiftUI
import Charts
import ChaiNetCore

/// Second layer: every statistic, expandable per topic. Engineers can inspect everything;
/// nothing measured is hidden, only collapsed.
struct TechnicalDetailsView: View {
    let result: TestResult
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let expanded = settings.settings.detailLevel == .expert
        let s = settings.settings
        VStack(spacing: 12) {
            SectionTitle(title: "技術細節", subtitle: "展開查看完整統計與原始資料")

            if let dl = result.download {
                TechnicalSection("下載統計", symbol: "arrow.down.circle", expanded: expanded) { SpeedDetail(result: dl, color: Theme.download, settings: s) }
            }
            if let ul = result.upload {
                TechnicalSection("上傳統計", symbol: "arrow.up.circle", expanded: expanded) { SpeedDetail(result: ul, color: Theme.upload, settings: s) }
            }
            if let idle = result.idleLatency {
                TechnicalSection("延遲（閒置 / 負載）", symbol: "dot.radiowaves.left.and.right", expanded: expanded) {
                    LatencyDetail(title: "閒置", stats: idle, samples: result.idleSamples)
                    if let dl = result.downloadLoadedLatency { Divider(); LatencyDetail(title: "下載時", stats: dl, samples: nil) }
                    if let ul = result.uploadLoadedLatency { Divider(); LatencyDetail(title: "上傳時", stats: ul, samples: nil) }
                }
            }
            if let loss = result.packetLoss {
                TechnicalSection("封包遺失 / 連續遺失", symbol: "drop.triangle", expanded: expanded) {
                    if let method = result.packetLossMethod { Text(method).font(.caption).foregroundStyle(Theme.textSecondary) }
                    LossDetail(loss: loss.loss)
                    LatencyDetail(title: "探測延遲", stats: loss, samples: nil)
                }
            }
            if let b = result.bufferbloat {
                TechnicalSection("Bufferbloat", symbol: "hourglass", expanded: expanded) { BufferbloatDetail(b: b) }
            }
            if let mon = result.monitoring {
                TechnicalSection("穩定度監測（突波 / 斷線）", symbol: "waveform", expanded: expanded) { MonitoringDetail(m: mon) }
            }
            if let dns = result.dns {
                TechnicalSection("DNS 解析器", symbol: "globe", expanded: expanded) { DNSDetail(dns: dns) }
            }
            if let p = result.protocolProbe {
                TechnicalSection("HTTP / TCP / TLS / QUIC", symbol: "lock.shield", expanded: expanded) { ProtocolDetail(p: p) }
            }
            if let ip = result.ipFamilyComparison {
                TechnicalSection("IPv4 / IPv6", symbol: "point.3.connected.trianglepath.dotted", expanded: expanded) { IPFamilyDetail(c: ip) }
            }
            if let checks = result.crossValidation {
                TechnicalSection("交叉驗證端點", symbol: "server.rack", expanded: expanded) { CrossValidationDetail(checks: checks) }
            }
            if let ifaces = result.interfaceCompare {
                TechnicalSection("介面比較", symbol: "arrow.left.arrow.right", expanded: expanded) {
                    ForEach(ifaces) { i in
                        KeyValueRow(key: i.interface.displayName, value: i.error ?? "中位數 \(Format.ms(i.tcpConnect?.rtt?.median, digits: 1)) · 遺失 \(Format.percent(i.tcpConnect?.loss.lossPercent))")
                    }
                    Text("以 TCP 連線時間同時量測各介面；iOS 無法指定 LTE / 5G。").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            if let mtu = result.mtu {
                TechnicalSection("MTU", symbol: "ruler", expanded: expanded) {
                    KeyValueRow(key: "路徑 MTU", value: mtu.pathMTU.map { "\($0) bytes" } ?? "無法判定")
                    KeyValueRow(key: "方法", value: mtu.method)
                    ForEach(Array(mtu.probes.enumerated()), id: \.offset) { _, p in
                        KeyValueRow(key: "\(p.packetSize) bytes", value: p.succeeded ? "通過" : (p.note ?? "失敗"),
                                    valueColor: p.succeeded ? Theme.good : Theme.textSecondary)
                    }
                }
            }
            if let tr = result.traceroute {
                TechnicalSection("路由追蹤", symbol: "point.topleft.down.to.point.bottomright.curvepath", expanded: expanded) { TracerouteDetail(tr: tr) }
            }
            QualityVerdictsSection(result: result, expanded: expanded)
            TechnicalSection("網路環境", symbol: "antenna.radiowaves.left.and.right", expanded: expanded) { NetworkEnvironmentDetail(n: result.network) }
            if let server = result.server {
                TechnicalSection("伺服器", symbol: "server.rack", expanded: expanded) {
                    KeyValueRow(key: "名稱", value: server.name)
                    KeyValueRow(key: "位置", value: server.location)
                    KeyValueRow(key: "URL", value: server.baseURL.absoluteString)
                    if let info = result.serverInfo {
                        KeyValueRow(key: "協定", value: info.httpProtocol)
                        KeyValueRow(key: "你的 IP（伺服器所見）", value: "\(info.clientIP) (\(info.clientIPFamily))")
                        KeyValueRow(key: "HTTP/3", value: info.supportsHTTP3 ? "支援" : "不支援")
                    }
                    if let h = result.serverHealth {
                        KeyValueRow(key: "健康狀態", value: h.healthy ? "正常 · \(Format.ms(h.responseMs))" : (h.detail ?? "異常"),
                                    valueColor: h.healthy ? Theme.good : Theme.critical)
                    }
                }
            }
            if !result.notes.isEmpty {
                TechnicalSection("備註", symbol: "note.text", expanded: true) {
                    ForEach(result.notes, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(Theme.textSecondary) }
                }
            }
        }
    }
}

struct SpeedDetail: View {
    let result: SpeedResult
    let color: Color
    let settings: AppSettings
    @State private var raw = false

    var body: some View {
        let s = result.summary
        Picker("圖表資料", selection: $raw) {
            Text("0.5 秒平滑").tag(false)
            Text("原始 0.1 秒").tag(true)
        }
        .pickerStyle(.segmented)
        ThroughputChart(samples: raw ? result.samples : SpeedSmoothing.movingAverage(result.samples, window: 5),
                        style: settings.chartStyle, unit: settings.primarySpeedUnit, color: color,
                        height: 150, averageMbps: s.averageMbps)
        KeyValueRow(key: "平均（時間加權）", value: Format.speed(s.averageMbps, settings: settings, secondary: true))
        KeyValueRow(key: "峰值（3 樣本移動平均）", value: Format.speed(s.peakMbps, settings: settings))
        KeyValueRow(key: "最低", value: Format.speed(s.minimumMbps, settings: settings))
        KeyValueRow(key: "中位數", value: Format.speed(s.medianMbps, settings: settings))
        KeyValueRow(key: "P95", value: Format.speed(s.p95Mbps, settings: settings))
        KeyValueRow(key: "P10（持續可用速度）", value: Format.speed(s.p10Mbps, settings: settings))
        KeyValueRow(key: "穩定度", value: "\(Format.number(s.stability.score, digits: 0)) / 100 · CV \(Format.number(s.stability.coefficientOfVariation, digits: 3))")
        KeyValueRow(key: "驟降次數（< 50% 中位數）", value: "\(s.stability.dropCount)")
        KeyValueRow(key: "傳輸量 / 時間", value: "\(Format.bytes(s.totalBytes)) / \(Format.number(s.duration, digits: 1)) 秒")
        KeyValueRow(key: "暖機樣本（排除）", value: "\(s.warmupSampleCount)")
        KeyValueRow(key: "平行連線", value: result.streamChanges.map { "\(Format.number($0.offset, digits: 1))s→\($0.streams)" }.joined(separator: "  "))
    }
}

struct LatencyDetail: View {
    let title: String
    let stats: LatencyStatistics
    let samples: [LatencySample]?

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
        if let r = stats.rtt {
            KeyValueRow(key: "最小 / 平均 / 中位數", value: "\(Format.ms(r.minimum, digits: 1)) / \(Format.ms(r.average, digits: 1)) / \(Format.ms(r.median, digits: 1))")
            KeyValueRow(key: "最大 / P95 / P99", value: "\(Format.ms(r.maximum, digits: 1)) / \(Format.ms(r.p95, digits: 1)) / \(Format.ms(r.p99, digits: 1))")
            KeyValueRow(key: "抖動（平均差 / RFC 3550）", value: "\(Format.ms(r.jitter, digits: 1)) / \(Format.ms(r.jitterRFC3550, digits: 1))")
            KeyValueRow(key: "標準差", value: Format.ms(r.standardDeviation, digits: 1))
        } else {
            Text("沒有收到任何回應").font(.caption).foregroundStyle(Theme.critical)
        }
        KeyValueRow(key: "收到 / 送出", value: "\(stats.received) / \(stats.sent)")
        if let samples, !samples.isEmpty {
            LatencyChart(samples: samples, height: 110)
            LatencyHistogram(rtts: samples.compactMap(\.rttMs))
        }
    }
}

struct LossDetail: View {
    let loss: LossAnalysis
    var body: some View {
        KeyValueRow(key: "遺失率", value: "\(Format.percent(loss.lossPercent, digits: 2))（\(loss.lost)/\(loss.sent)）",
                    valueColor: loss.lossPercent > 2 ? Theme.critical : Theme.textPrimary)
        KeyValueRow(key: "隨機遺失", value: "\(Format.percent(loss.randomLossPercent, digits: 2)) · \(loss.randomLossEvents) 次")
        KeyValueRow(key: "連續遺失（≥ \(loss.burstThreshold)）", value: "\(Format.percent(loss.burstLossPercent, digits: 2)) · \(loss.burstEvents) 次")
        KeyValueRow(key: "最長連續遺失", value: "\(loss.longestBurst) 個封包")
        KeyValueRow(key: "Gilbert p / r", value: "\(Format.number(loss.lossProbabilityAfterReceive, digits: 3)) / \(Format.number(loss.recoveryProbabilityAfterLoss, digits: 3))")
    }
}

struct BufferbloatDetail: View {
    let b: BufferbloatResult
    var body: some View {
        Chart3Bars(idle: b.idleMedianMs, download: b.downloadLoadedMedianMs, upload: b.uploadLoadedMedianMs)
        KeyValueRow(key: "等級", value: b.grade.rawValue)
        KeyValueRow(key: "閒置中位數", value: Format.ms(b.idleMedianMs, digits: 1))
        KeyValueRow(key: "下載時", value: "\(Format.ms(b.downloadLoadedMedianMs, digits: 1))（+\(Format.ms(b.downloadIncreaseMs, digits: 0))，\(b.downloadGrade?.rawValue ?? "—")）")
        KeyValueRow(key: "上傳時", value: "\(Format.ms(b.uploadLoadedMedianMs, digits: 1))（+\(Format.ms(b.uploadIncreaseMs, digits: 0))，\(b.uploadGrade?.rawValue ?? "—")）")
    }
}

/// Idle vs loaded latency bars.
struct Chart3Bars: View {
    let idle: Double
    let download: Double?
    let upload: Double?
    var body: some View {
        Chart {
            BarMark(x: .value("狀態", "閒置"), y: .value("ms", idle)).foregroundStyle(Theme.good)
            if let download { BarMark(x: .value("狀態", "下載時"), y: .value("ms", download)).foregroundStyle(Theme.download) }
            if let upload { BarMark(x: .value("狀態", "上傳時"), y: .value("ms", upload)).foregroundStyle(Theme.upload) }
        }
        .chartYAxisLabel("ms")
        .frame(height: 120)
    }
}

struct MonitoringDetail: View {
    let m: MonitoringResult
    var body: some View {
        KeyValueRow(key: "目標 / 間隔", value: "\(m.target) · \(Format.number(m.intervalSeconds, digits: 2)) 秒")
        KeyValueRow(key: "探測數", value: "\(m.samples.count)")
        KeyValueRow(key: "延遲突波", value: "\(m.spikes.count) 次")
        KeyValueRow(key: "斷線", value: "\(m.drops.count) 次", valueColor: m.drops.isEmpty ? Theme.textPrimary : Theme.critical)
        KeyValueRow(key: "路徑變更", value: "\(m.pathChanges.count) 次")
        LatencyChart(samples: m.samples.sorted { $0.sequence < $1.sequence }, height: 120)
        ForEach(Array(m.drops.enumerated()), id: \.offset) { _, d in
            Text("斷線 @ \(Format.number(d.startOffset, digits: 1))s，持續 \(Format.number(d.duration, digits: 1))s，\(d.lostProbes) 個探測無回應")
                .font(.caption).foregroundStyle(Theme.critical)
        }
    }
}

struct DNSDetail: View {
    let dns: DNSBenchmarkResult
    var body: some View {
        ForEach(dns.ranked) { r in
            VStack(alignment: .leading, spacing: 2) {
                KeyValueRow(key: r.resolver.name, value: "\(Format.ms(r.statistics.rtt?.median, digits: 1)) · P95 \(Format.ms(r.statistics.rtt?.p95, digits: 0))")
                Text("\(r.resolver.transport.rawValue.uppercased()) · 失敗 \(r.statistics.loss.lost)/\(r.statistics.sent)")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        Text("查詢網域：\(dns.domains.joined(separator: ", "))").font(.caption2).foregroundStyle(Theme.textSecondary)
    }
}

struct ProtocolDetail: View {
    let p: ProtocolProbeResult
    var body: some View {
        if let h = p.http {
            KeyValueRow(key: "協商協定", value: h.negotiatedProtocol.displayName)
            KeyValueRow(key: "DNS", value: Format.ms(h.dnsMs, digits: 1))
            KeyValueRow(key: "TCP 連線", value: Format.ms(h.tcpConnectMs, digits: 1))
            KeyValueRow(key: "TLS 交握", value: "\(Format.ms(h.tlsMs, digits: 1)) · \(h.tlsVersion ?? "—")")
            KeyValueRow(key: "TTFB", value: Format.ms(h.ttfbMs, digits: 1))
            KeyValueRow(key: "總時間", value: Format.ms(h.totalMs, digits: 1))
            KeyValueRow(key: "遠端位址", value: h.remoteAddress ?? "—")
        }
        KeyValueRow(key: "HTTP/3 嘗試", value: p.http3Attempt?.negotiatedProtocol.displayName ?? "—")
        AvailabilityRow(key: "QUIC 交握", availability: p.quicHandshakeMs) { Format.ms($0, digits: 1) }
        KeyValueRow(key: "TCP 連線（5 次中位數）", value: Format.ms(p.tcpConnect?.rtt?.median, digits: 1))
        KeyValueRow(key: "TCP+TLS 就緒（中位數）", value: Format.ms(p.tlsConnect?.rtt?.median, digits: 1))
        KeyValueRow(key: "HTTP 延遲（熱連線）", value: Format.ms(p.httpLatency?.rtt?.median, digits: 1))
        AvailabilityRow(key: "IPv4 連線", availability: p.ipv4Reachable) { Format.ms($0, digits: 1) }
        AvailabilityRow(key: "IPv6 連線", availability: p.ipv6Reachable) { Format.ms($0, digits: 1) }
        ForEach(p.errors, id: \.self) { Text($0).font(.caption2).foregroundStyle(Theme.warning) }
    }
}

struct IPFamilyDetail: View {
    let c: IPFamilyComparisonResult
    var body: some View {
        KeyValueRow(key: "目標", value: c.target)
        KeyValueRow(key: "IPv4", value: c.ipv4Error ?? "中位數 \(Format.ms(c.ipv4?.rtt?.median, digits: 1)) · 遺失 \(Format.percent(c.ipv4?.loss.lossPercent))")
        KeyValueRow(key: "IPv6", value: c.ipv6Error ?? "中位數 \(Format.ms(c.ipv6?.rtt?.median, digits: 1)) · 遺失 \(Format.percent(c.ipv6?.loss.lossPercent))")
    }
}

struct CrossValidationDetail: View {
    let checks: [EndpointCheck]
    var body: some View {
        ForEach(checks) { c in
            let health = TestHealthEvaluator.assess(c.statistics, error: c.error)
            HStack {
                Image(systemName: health.isDegraded ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(health.isDegraded ? Theme.warning : Theme.good)
                VStack(alignment: .leading) {
                    Text(c.name + (c.isPrimary ? "（主要伺服器）" : "")).font(.footnote.weight(.medium))
                    Text("\(c.region) · \(c.method.rawValue)").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(c.error ?? "\(Format.ms(c.statistics?.rtt?.median)) · \(Format.percent(c.statistics?.loss.lossPercent))")
                    .font(.caption.monospacedDigit())
            }
        }
    }
}

struct TracerouteDetail: View {
    let tr: TracerouteResult
    var body: some View {
        KeyValueRow(key: "目標", value: "\(tr.target) (\(tr.resolvedAddress))")
        ForEach(tr.hops) { hop in
            HStack(alignment: .top) {
                Text("\(hop.ttl)").font(.caption.monospacedDigit()).frame(width: 22, alignment: .trailing).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hop.address ?? "*").font(.caption.monospaced())
                    if let name = hop.hostname { Text(name).font(.caption2).foregroundStyle(Theme.textSecondary) }
                }
                Spacer()
                Text(hop.rttsMs.map { $0.map { String(format: "%.0f", $0) } ?? "*" }.joined(separator: " / ") + " ms")
                    .font(.caption.monospacedDigit())
            }
        }
        Text(tr.method + "。「*」代表該節點不回應 ICMP，不一定是遺失。").font(.caption2).foregroundStyle(Theme.textSecondary)
    }
}

struct NetworkEnvironmentDetail: View {
    let n: NetworkSnapshot
    var body: some View {
        KeyValueRow(key: "介面", value: n.primaryInterface.displayName)
        KeyValueRow(key: "IPv4 / IPv6 / DNS", value: "\(n.supportsIPv4 ? "✓" : "✗") / \(n.supportsIPv6 ? "✓" : "✗") / \(n.supportsDNS ? "✓" : "✗")")
        KeyValueRow(key: "計量網路（Expensive）", value: n.isExpensive ? "是" : "否")
        KeyValueRow(key: "低數據模式（Constrained）", value: n.isConstrained ? "開啟" : "關閉")
        KeyValueRow(key: "VPN", value: "\(vpnText) · \(n.vpn.method)")
        AvailabilityRow(key: "公用 IPv4", availability: n.publicIPv4) { $0 }
        AvailabilityRow(key: "公用 IPv6", availability: n.publicIPv6) { $0 }
        ForEach(Array(n.localAddresses.prefix(6).enumerated()), id: \.offset) { _, a in
            KeyValueRow(key: "本機 \(a.interfaceName)", value: a.address)
        }
        if let c = n.cellular {
            AvailabilityRow(key: "無線電制式", availability: c.radioTechnology) { "\($0.generationLabel) (\($0.rawValue))" }
            AvailabilityRow(key: "頻段", availability: c.signal.band) { $0 }
            AvailabilityRow(key: "RSRP", availability: c.signal.rsrp) { "\(Int($0)) dBm" }
            AvailabilityRow(key: "RSRQ", availability: c.signal.rsrq) { "\(Int($0)) dB" }
            AvailabilityRow(key: "SINR", availability: c.signal.sinr) { "\(Int($0)) dB" }
            AvailabilityRow(key: "Cell ID", availability: c.signal.cellID) { $0 }
            AvailabilityRow(key: "電信商", availability: c.carrierName) { $0 }
        }
        if let w = n.wifi {
            AvailabilityRow(key: "SSID", availability: w.ssid) { $0 }
            AvailabilityRow(key: "RSSI", availability: w.rssi) { "\(Int($0)) dBm" }
        }
    }

    private var vpnText: String {
        switch n.vpn.state {
        case .detected: "偵測到"
        case .notDetected: "未偵測到"
        case .unknown: "未知"
        }
    }
}

/// Gaming / Voice / Streaming / OBS verdict tables.
struct QualityVerdictsSection: View {
    let result: TestResult
    let expanded: Bool
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if let g = result.gaming {
            TechnicalSection("遊戲適用性", symbol: "gamecontroller", expanded: true) {
                ForEach(g.verdicts) { v in
                    HStack {
                        Text(v.genre.displayName).font(.footnote)
                        Spacer()
                        if !v.limitingFactors.isEmpty {
                            Text(v.limitingFactors.joined(separator: "、")).font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                        Badge(text: v.verdict.displayName, color: v.verdict.color)
                    }
                }
                KeyValueRow(key: "封包速率", value: "\(Int(g.packetsPerSecond)) pps")
                KeyValueRow(key: "延遲突波", value: "\(g.spikes.count) 次")
            }
        }
        if let v = result.voice {
            TechnicalSection("語音品質（E-model）", symbol: "phone.bubble", expanded: true) {
                KeyValueRow(key: "MOS", value: Format.number(v.mos, digits: 2))
                KeyValueRow(key: "R 值", value: Format.number(v.rFactor, digits: 1))
                KeyValueRow(key: "有效延遲", value: Format.ms(v.effectiveLatencyMs))
                KeyValueRow(key: "評等", value: voiceRating(v.rating))
                KeyValueRow(key: "模擬串流", value: "\(Int(v.packetsPerSecond)) pps × \(v.payloadBytes) B（G.711 20 ms）")
            }
        }
        if let st = result.streaming {
            TechnicalSection("串流適用性", symbol: "play.tv", expanded: true) {
                KeyValueRow(key: "持續速度（P10）", value: Format.speed(st.sustainedMbps, settings: settings.settings))
                KeyValueRow(key: "最高可穩定播放", value: st.maxSupportedTier?.name ?? "低於 480p")
                KeyValueRow(key: "預估起播時間", value: Format.ms(st.estimatedStartupMs))
                ForEach(st.tiers) { t in
                    KeyValueRow(key: "\(t.tier.name)（\(Int(t.tier.requiredMbps)) Mbps）", value: t.supported ? "✓" : "✗",
                                valueColor: t.supported ? Theme.good : Theme.critical)
                }
            }
        }
        if let o = result.obs {
            TechnicalSection("OBS 直播上傳", symbol: "video.badge.waveform", expanded: true) {
                KeyValueRow(key: "持續上傳（P10）", value: Format.speed(o.sustainedMbps, settings: settings.settings))
                KeyValueRow(key: "建議位元率", value: "\(Int(o.recommendedBitrateKbps)) kbps")
                ForEach(o.presets) { p in
                    HStack {
                        Text("\(p.preset.name) · \(Int(p.preset.bitrateKbps)) kbps").font(.footnote)
                        Spacer()
                        Badge(text: p.verdict.displayName, color: p.verdict.color)
                    }
                }
                ForEach(o.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.warning) }
            }
        }
    }

    private func voiceRating(_ r: VoiceRating) -> String {
        switch r {
        case .excellent: "極佳"
        case .good: "良好"
        case .fair: "尚可"
        case .poor: "差"
        case .bad: "很差"
        }
    }
}
