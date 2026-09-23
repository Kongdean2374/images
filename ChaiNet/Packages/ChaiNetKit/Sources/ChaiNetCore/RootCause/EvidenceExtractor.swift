import Foundation

public struct EvidenceSet: Codable, Sendable, Hashable {
    public var evidence: [DiagnosticEvidence]
    /// Dimensions that were actually measured (even when they produced no notable evidence).
    public var measuredDimensions: Set<EvidenceDimension>
    /// Dimensions for which a test was *run*, even if the result was inconclusive (e.g. a
    /// cross-server check where only one endpoint answered). Attempted but not measured →
    /// "insufficient evidence"; never attempted → "not tested".
    public var attemptedDimensions: Set<EvidenceDimension>
    public var crossTest: CrossTestReport?
    public var baselineComparisons: [BaselineComparison]

    public init(evidence: [DiagnosticEvidence], measuredDimensions: Set<EvidenceDimension>,
                attemptedDimensions: Set<EvidenceDimension>? = nil,
                crossTest: CrossTestReport? = nil, baselineComparisons: [BaselineComparison] = []) {
        self.evidence = evidence
        self.measuredDimensions = measuredDimensions
        self.attemptedDimensions = (attemptedDimensions ?? []).union(measuredDimensions)
        self.crossTest = crossTest
        self.baselineComparisons = baselineComparisons
    }

    public var codes: Set<EvidenceCode> { Set(evidence.map(\.code)) }
}

/// Turns raw measurements into evidence (facts with values). Thresholds:
///
/// | Evidence               | Rule                                                        |
/// |------------------------|-------------------------------------------------------------|
/// | downloadHigh / Normal / Low | ≥ 100 / ≥ 10 / < 10 Mbps                               |
/// | uploadVeryLow / Low / Normal | < 3 / < 10 / ≥ 10 Mbps                                |
/// | asymmetricRatio        | download / upload ≥ 20                                      |
/// | *Unstable / *Stable    | stability score < 50 / ≥ 80                                 |
/// | idleLatencyLow / High  | median < 30 / > 100 ms                                      |
/// | jitterHigh / Low       | > 30 / < 10 ms                                              |
/// | lossNone               | < 0.5 % with ≥ 20 probes                                    |
/// | lossHigh / Severe      | > 2 % / > 5 %                                               |
/// | lossBursty / Random    | pattern burst|mixed with burst loss ≥ 0.5 % / pattern random |
/// | latencySpikesFrequent  | ≥ 3 spikes                                                  |
/// | *Bufferbloat           | loaded − idle median > 100 ms; noBufferbloat: all < 30 ms   |
/// | dnsSlow / Failures     | system median > 100 ms or > best + 30 ms / ≥ 20 % failures  |
/// | tcpConnectSlow / tlsSlow / ttfbSlow | > 150 / > 250 / TTFB − TCP − TLS > 300 ms      |
/// | quicBlocked            | QUIC failed while HTTP worked, server known to support h3   |
/// | mtuReduced / Normal    | path MTU < 1400 / ≥ 1400                                    |
public struct EvidenceExtractor: Sendable {
    public var crossTestAnalyzer: CrossTestAnalyzer
    public var anomalyDetector: AnomalyDetector

    public init(crossTestAnalyzer: CrossTestAnalyzer = CrossTestAnalyzer(), anomalyDetector: AnomalyDetector = AnomalyDetector()) {
        self.crossTestAnalyzer = crossTestAnalyzer
        self.anomalyDetector = anomalyDetector
    }

    public func extract(from session: DiagnosticSession, baselines: BaselineStore? = nil, calendar: Calendar = .current) -> EvidenceSet {
        var evidence: [DiagnosticEvidence] = []
        var measured: Set<EvidenceDimension> = []

        for test in session.tests {
            let (e, m) = extract(test: test)
            evidence += e
            measured.formUnion(m)
        }

        // Session-level environment facts.
        let classes = session.tests.map(\.networkClass)
        if !session.tests.isEmpty {
            if !classes.contains(where: \.isCellular) {
                evidence.append(DiagnosticEvidence(code: .noCellularTests, statement: "本次工作階段沒有行動網路測試"))
            } else if !classes.contains(.nr) && classes.contains(.lte) {
                evidence.append(DiagnosticEvidence(code: .no5GTests, statement: "行動網路測試皆為 LTE，未使用 5G"))
            }
        }

        // Cross-test comparisons.
        let cross = crossTestAnalyzer.analyze(session, endpointBaselines: baselines?.endpoints ?? [])
        evidence += crossEvidence(cross, measured: &measured)

        // Baseline.
        var comparisons: [BaselineComparison] = []
        if let baselines {
            for test in session.tests {
                let c = anomalyDetector.compare(test.result, store: baselines, calendar: calendar)
                comparisons.append(c)
                let iface = test.result.network.primaryInterface
                if c.baseline == nil {
                    evidence.append(DiagnosticEvidence(code: .noBaseline, statement: "\(test.label)：此網路類型尚無足夠歷史資料建立基準",
                                                       testIDs: [test.id], interface: iface))
                } else if c.anomalies.isEmpty {
                    measured.insert(.baseline)
                    evidence.append(DiagnosticEvidence(code: .matchesBaseline, statement: "\(test.label)：結果與此裝置歷史基準一致",
                                                       testIDs: [test.id], interface: iface))
                } else {
                    measured.insert(.baseline)
                    let text = c.anomalies.map(\.summary).joined(separator: "；")
                    evidence.append(DiagnosticEvidence(code: .deviatesFromBaseline, statement: "\(test.label)：偏離歷史基準 — \(text)",
                                                       value: c.anomalies.map(\.robustZ).max(), unit: "z", testIDs: [test.id], interface: iface))
                }
            }
        }
        // Attempted = a test for the dimension ran, whatever its outcome.
        var attempted = measured
        let results = session.tests.map(\.result)
        if results.contains(where: { $0.crossValidation != nil }) || Set(results.compactMap { $0.server?.id }).count >= 2 {
            attempted.insert(.crossServer)
        }
        if results.contains(where: { $0.ipFamilyComparison != nil || $0.ipFamilyPreference != .automatic }) { attempted.insert(.ipFamily) }
        if results.contains(where: { $0.interfaceCompare != nil }) || Set(classes.filter { $0 != .unknown }).count >= 2 {
            attempted.insert(.interfaceCompare)
        }
        if classes.contains(.lte) && classes.contains(.nr) { attempted.insert(.radioCompare) }
        if baselines != nil { attempted.insert(.baseline) }
        if results.contains(where: { $0.dns != nil }) { attempted.insert(.dns) }
        if results.contains(where: { $0.protocolProbe != nil }) { attempted.insert(.protocols) }
        if results.contains(where: { $0.mtu != nil }) { attempted.insert(.mtu) }
        if results.contains(where: { $0.monitoring != nil }) { attempted.insert(.stabilityMonitoring) }
        return EvidenceSet(evidence: evidence, measuredDimensions: measured, attemptedDimensions: attempted,
                           crossTest: cross, baselineComparisons: comparisons)
    }

    // MARK: Per test

    public func extract(test: SessionTest) -> ([DiagnosticEvidence], Set<EvidenceDimension>) {
        let r = test.result
        let m = r.metrics
        let id = test.id
        let iface = r.network.primaryInterface
        let label = test.label
        var out: [DiagnosticEvidence] = []
        var measured: Set<EvidenceDimension> = []

        func add(_ code: EvidenceCode, _ text: String, _ value: Double? = nil, _ unit: String? = nil) {
            out.append(DiagnosticEvidence(code: code, statement: "\(label)：\(text)", value: value, unit: unit, testIDs: [id], interface: iface))
        }

        // Environment
        measured.insert(.environment)
        switch NetworkClass(snapshot: r.network) {
        case .wifi, .wired: add(.onWiFi, "使用 \(iface.displayName)")
        case .lte: add(.onCellular, "使用行動網路（LTE）"); add(.onLTE, "無線電制式：LTE")
        case .nr:
            add(.onCellular, "使用行動網路（5G）")
            let tech = r.network.cellular?.radioTechnology.value
            add(.on5G, "無線電制式：\(tech?.generationLabel ?? "5G")")
        case .cellularOther: add(.onCellular, "使用行動網路（制式：\(r.network.cellular?.radioTechnology.value?.generationLabel ?? "不明")）")
        case .unknown: break
        }
        if iface == .cellular {
            add(.cellularRadioMetricsUnavailable, "RSRP / RSRQ / SINR / 頻段 / Cell ID：iOS 不提供（unavailable）")
        }
        switch r.network.vpn.state {
        case .detected: add(.vpnActive, "偵測到 VPN（\(r.network.vpn.interfaces.joined(separator: ", "))，\(r.network.vpn.method)）")
        case .notDetected: add(.vpnInactive, "未偵測到 VPN")
        case .unknown: break
        }
        if r.network.status == .satisfied {
            if r.network.isConstrained { add(.lowDataMode, "低數據模式開啟") } else { add(.notConstrained, "低數據模式關閉") }
        }
        if let health = r.serverHealth {
            if health.healthy { add(.serverHealthy, "測速伺服器健康檢查正常") }
            else { add(.serverUnhealthy, "測速伺服器健康檢查異常\(health.detail.map { "：\($0)" } ?? "")") }
        }

        // Throughput
        if let dl = m.downloadMbps {
            measured.insert(.throughput)
            if dl >= 100 { add(.downloadHigh, "下載 \(Fmt.d(dl, 1)) Mbps — 下行容量正常", dl, "Mbps") }
            else if dl >= 10 { add(.downloadNormal, "下載 \(Fmt.d(dl, 1)) Mbps", dl, "Mbps") }
            else { add(.downloadLow, "下載僅 \(Fmt.d(dl, 1)) Mbps（< 10）", dl, "Mbps") }
        }
        if let ul = m.uploadMbps {
            measured.insert(.throughput)
            if ul < 3 { add(.uploadVeryLow, "上傳僅 \(Fmt.d(ul, 2)) Mbps（< 3）", ul, "Mbps") }
            else if ul < 10 { add(.uploadLow, "上傳 \(Fmt.d(ul, 1)) Mbps（< 10）", ul, "Mbps") }
            else { add(.uploadNormal, "上傳 \(Fmt.d(ul, 1)) Mbps", ul, "Mbps") }
        }
        if let dl = m.downloadMbps, let ul = m.uploadMbps, ul > 0, dl / ul >= 20 {
            add(.asymmetricRatio, "下載 / 上傳比 \(Fmt.d(dl / ul, 0)):1", dl / ul, "×")
        }
        if let s = m.downloadStability {
            if s < 50 { add(.downloadUnstable, "下載穩定度 \(Fmt.d(s, 0))%", s, "%") }
            else if s >= 80 { add(.downloadStable, "下載穩定度 \(Fmt.d(s, 0))%", s, "%") }
        }
        if let s = m.uploadStability {
            if s < 50 { add(.uploadUnstable, "上傳穩定度 \(Fmt.d(s, 0))%", s, "%") }
            else if s >= 80 { add(.uploadStable, "上傳穩定度 \(Fmt.d(s, 0))%", s, "%") }
        }

        // Latency
        if let lat = m.idleLatencyMs {
            measured.insert(.latency)
            if lat < 30 { add(.idleLatencyLow, "閒置延遲僅 \(Fmt.d(lat, 0)) ms", lat, "ms") }
            else if lat > 100 { add(.idleLatencyHigh, "閒置延遲 \(Fmt.d(lat, 0)) ms（> 100）", lat, "ms") }
        }
        if let j = m.jitterMs {
            measured.insert(.latency)
            if j > 30 { add(.jitterHigh, "抖動 \(Fmt.d(j, 0)) ms（> 30）", j, "ms") }
            else if j < 10 { add(.jitterLow, "抖動 \(Fmt.d(j, 1)) ms", j, "ms") }
        }
        if let spikes = m.spikeCount {
            measured.insert(.latency)
            if spikes >= 3 { add(.latencySpikesFrequent, "延遲突波 \(spikes) 次", Double(spikes), "次") }
        }

        // Loss
        let lossStats = r.packetLoss ?? r.gaming?.idle ?? r.voice?.latency ?? r.monitoring?.statistics ?? r.idleLatency
        if let loss = lossStats?.loss, loss.sent > 0 {
            measured.insert(.loss)
            let method = r.packetLossMethod.map { "，\($0)" } ?? ""
            if loss.lossPercent > 5 { add(.lossSevere, "封包遺失 \(Fmt.d(loss.lossPercent, 1))%（> 5%\(method)）", loss.lossPercent, "%") }
            if loss.lossPercent > 2 { add(.lossHigh, "封包遺失 \(Fmt.d(loss.lossPercent, 1))%（\(loss.lost)/\(loss.sent)\(method)）", loss.lossPercent, "%") }
            if loss.lossPercent < 0.5 && loss.sent >= 20 { add(.lossNone, "封包遺失 \(Fmt.d(loss.lossPercent, 2))%（\(loss.sent) 個探測）", loss.lossPercent, "%") }
            if (loss.pattern == .burst || loss.pattern == .mixed) && loss.burstLossPercent >= 0.5 {
                add(.lossBursty, "連續遺失 \(loss.burstEvents) 次，最長 \(loss.longestBurst) 個封包（burst \(Fmt.d(loss.burstLossPercent, 1))%）", loss.burstLossPercent, "%")
            } else if loss.pattern == .random {
                add(.lossRandom, "遺失為零星隨機型（\(loss.randomLossEvents) 次）", loss.randomLossPercent, "%")
            }
        }

        // Bufferbloat
        let dlBloat = m.downloadBloatMs, ulBloat = m.uploadBloatMs
        if dlBloat != nil || ulBloat != nil {
            measured.insert(.bufferbloat)
            if let v = dlBloat, v > 100 { add(.downloadBufferbloat, "下載時延遲增加 \(Fmt.d(v, 0)) ms", v, "ms") }
            if let v = ulBloat, v > 100 { add(.uploadBufferbloat, "上傳時延遲增加 \(Fmt.d(v, 0)) ms", v, "ms") }
            if [dlBloat, ulBloat].compactMap({ $0 }).allSatisfy({ $0 < 30 }) {
                add(.noBufferbloat, "滿載時延遲增加 < 30 ms（下載 \(dlBloat.map { Fmt.d($0, 0) } ?? "—") / 上傳 \(ulBloat.map { Fmt.d($0, 0) } ?? "—") ms）")
            }
        }

        // DNS
        if let dns = r.dns, let system = dns.resolvers.first(where: { $0.resolver.transport == .system }) {
            measured.insert(.dns)
            let failureRate = system.statistics.loss.lossPercent
            if failureRate >= 20 {
                add(.dnsFailures, "系統 DNS 失敗率 \(Fmt.d(failureRate, 0))%", failureRate, "%")
            }
            if let sys = system.statistics.rtt?.median {
                if sys > 100 || (m.bestDNSMs.map { sys - $0 > 30 } ?? false) {
                    add(.dnsSlow, "系統 DNS 中位數 \(Fmt.d(sys, 0)) ms（最佳 \(m.bestDNSName ?? "—") \(m.bestDNSMs.map { Fmt.d($0, 0) } ?? "—") ms）", sys, "ms")
                } else if failureRate < 20 {
                    add(.dnsHealthy, "系統 DNS 中位數 \(Fmt.d(sys, 0)) ms，無明顯失敗", sys, "ms")
                }
            }
        }

        // Protocols
        if let probe = r.protocolProbe {
            measured.insert(.protocols)
            if let tcp = probe.tcpConnect?.rtt?.median ?? probe.http?.tcpConnectMs, tcp > 150 {
                add(.tcpConnectSlow, "TCP 連線建立 \(Fmt.d(tcp, 0)) ms", tcp, "ms")
            }
            if let tls = probe.http?.tlsMs, tls > 250 { add(.tlsSlow, "TLS 交握 \(Fmt.d(tls, 0)) ms", tls, "ms") }
            if let http = probe.http, let ttfb = http.ttfbMs {
                let server = ttfb - (http.tcpConnectMs ?? 0) - (http.tlsMs ?? 0)
                if server > 300 { add(.ttfbSlow, "TTFB \(Fmt.d(ttfb, 0)) ms，扣除連線後伺服器回應約 \(Fmt.d(server, 0)) ms", ttfb, "ms") }
            }
            // Statements quote the protocol that was actually negotiated (never assume HTTP/2).
            let httpProto = probe.http?.negotiatedProtocol.displayName ?? "HTTP"
            let assessment = probe.quicAssessment ?? (probe.quicHandshakeMs.value != nil ? .working : nil)
            if probe.http3Attempt?.negotiatedProtocol == .http3 || assessment == .working {
                add(.http3Negotiated, "HTTP/3（QUIC）可用：至少一個端點完成 QUIC 交握")
            } else if let assessment {
                let hosts = (probe.quicProbes ?? []).map { "\($0.host)（\($0.failure?.rawValue ?? "ok")，TCP \($0.tcpReachable == true ? "可連" : "不可連")）" }
                    .joined(separator: "、")
                switch assessment {
                case .probableUDPBlocking:
                    add(.quicBlocked, "\(probe.quicProbes?.count ?? 0) 個獨立端點 QUIC 交握皆逾時，但 TCP 443 可連（\(httpProto) 正常）：\(hosts)")
                case .implementationFailure:
                    add(.quicImplementationFailure, "各端點 QUIC 皆出現相同協定錯誤，較像本機 / 實作層問題而非網路封鎖：\(hosts)")
                case .endpointFailure:
                    add(.quicEndpointFailure, "QUIC 交握失敗僅限個別端點或樣本不足，無法推論為 UDP 封鎖：\(hosts)")
                case .working, .notTested:
                    break
                }
            }
        }

        // MTU
        if let mtu = r.mtu?.pathMTU {
            measured.insert(.mtu)
            let target = r.mtu?.target ?? "目標"
            if mtu < 1400 { add(.mtuReduced, "IPv4 → \(target) 路徑 MTU \(mtu) bytes", Double(mtu), "bytes") }
            else { add(.mtuNormal, "IPv4 → \(target) 路徑 MTU \(mtu) bytes：受測路徑未觀察到 MTU 問題（noIssueObservedOnTestedPath，不代表其他路徑）", Double(mtu), "bytes") }
        }

        // Monitoring
        if let mon = r.monitoring {
            measured.insert(.stabilityMonitoring)
            if !mon.drops.isEmpty {
                let longest = mon.drops.compactMap(\.duration).max() ?? 0
                add(.connectionDrops, "監測期間斷線 \(mon.drops.count) 次（最長約 \(Fmt.d(longest, 0)) 秒）", Double(mon.drops.count), "次")
            } else if mon.samples.count >= 60 {
                add(.noDropsObserved, "連續 \(mon.samples.count) 個探測未發生斷線", Double(mon.samples.count), "個")
            }
            if !mon.pathChanges.isEmpty {
                add(.pathChanged, "網路路徑變更 \(mon.pathChanges.count) 次", Double(mon.pathChanges.count), "次")
            }
        }
        return (out, measured)
    }

    // MARK: Cross-test

    func crossEvidence(_ cross: CrossTestReport, measured: inout Set<EvidenceDimension>) -> [DiagnosticEvidence] {
        var out: [DiagnosticEvidence] = []
        var measuredNote = ""
        let s = cross.servers
        let anomalousNames = s.entries.filter(\.isAnomalous).map { "\($0.name)（\($0.reasons.joined(separator: "、"))）" }
        let total = s.entries.filter { $0.status != .notMeasured }.count
        let unavailable = s.entries.filter { $0.status == .notMeasured }
        if !unavailable.isEmpty {
            measuredNote = "（另有 \(unavailable.count) 個端點無法測試，不列入判斷：\(unavailable.map(\.name).joined(separator: "、"))）"
        }
        switch s.verdict {
        case .insufficientData: break
        case .allNormal:
            out.append(DiagnosticEvidence(code: .allServersNormal, statement: "\(total) 個獨立伺服器 / 端點皆正常\(measuredNote)"))
        case .singleServerAnomalous:
            out.append(DiagnosticEvidence(code: .singleServerAnomalous, statement: "僅 1 個伺服器異常：\(anomalousNames.joined(separator: "；"))，其他 \(total - 1) 個正常"))
        case .multipleServersAnomalous:
            out.append(DiagnosticEvidence(code: .multipleServersAnomalous, statement: "\(anomalousNames.count)/\(total) 個伺服器異常：\(anomalousNames.joined(separator: "；"))"))
        case .allServersAnomalous:
            out.append(DiagnosticEvidence(code: .allServersAnomalous, statement: "全部 \(total) 個可測試的獨立伺服器皆出現異常\(measuredNote)"))
        }
        if s.verdict != .insufficientData { measured.insert(.crossServer) }
        let slower = s.entries.filter { $0.higherLatencyRelativeToPeers && !$0.isAnomalous }
        if !slower.isEmpty {
            out.append(DiagnosticEvidence(code: .higherLatencyRelativeToPeers,
                statement: "延遲高於其他端點（僅供參考，不同 Anycast 業者節點位置不同，不視為異常）：" +
                    slower.map { "\($0.name) \(Fmt.d($0.latencyMedianMs ?? 0, 0)) ms" }.joined(separator: "、")))
        }
        if let region = s.anomalousRegion {
            out.append(DiagnosticEvidence(code: .regionSpecificAnomaly, statement: "異常集中在「\(region)」區域的伺服器，其他區域正常"))
        }
        if let consistent = s.throughputConsistent {
            measured.insert(.crossServer)
            if consistent {
                out.append(DiagnosticEvidence(code: .crossServerConsistentThroughput, statement: "多個伺服器測得的下載速度一致（差距 < 50%）"))
            } else {
                let names = s.entries.filter { s.throughputOutlierIDs.contains($0.id) }.map(\.name)
                out.append(DiagnosticEvidence(code: .serverThroughputOutlierLow, statement: "\(names.joined(separator: "、")) 的下載速度低於最佳伺服器的 50%"))
            }
        }

        let ip = cross.ipFamilies
        func ms(_ v: Double?) -> String { v.map { "\(Fmt.d($0, 0)) ms" } ?? "—" }
        func pct(_ v: Double?) -> String { v.map { "\(Fmt.d($0, 1))%" } ?? "—" }
        let ipText = "IPv4 \(ms(ip.ipv4MedianMs)) / 遺失 \(pct(ip.ipv4LossPercent))；IPv6 \(ms(ip.ipv6MedianMs)) / 遺失 \(pct(ip.ipv6LossPercent))"
        switch ip.verdict {
        case .insufficientData: break
        case .equivalent: out.append(DiagnosticEvidence(code: .ipFamiliesEquivalent, statement: "IPv4 與 IPv6 表現相近（\(ipText)）"))
        case .ipv6Degraded: out.append(DiagnosticEvidence(code: .ipv6DegradedOnly, statement: "只有 IPv6 劣化（\(ipText)）"))
        case .ipv4Degraded: out.append(DiagnosticEvidence(code: .ipv4DegradedOnly, statement: "只有 IPv4 劣化（\(ipText)）"))
        case .bothDegraded: out.append(DiagnosticEvidence(code: .ipFamiliesEquivalent, statement: "IPv4 與 IPv6 同樣劣化（\(ipText)）"))
        case .ipv6Unavailable: out.append(DiagnosticEvidence(code: .ipv6Unavailable, statement: "IPv6 無法連線，IPv4 正常"))
        }
        if ip.verdict != .insufficientData { measured.insert(.ipFamily) }

        let i = cross.interfaces
        for u in i.unavailable {
            out.append(DiagnosticEvidence(code: .interfaceProbeUnavailable,
                                          statement: "\(u.networkClass.displayName) 介面無法測試（\(u.reason)）— 視為未測試，不視為異常",
                                          testIDs: [u.testID]))
        }
        let groupText = i.groups.map { "\($0.networkClass.displayName)：\($0.degraded ? "異常（\($0.reasons.prefix(3).joined(separator: "、"))）" : "正常")" }
            .joined(separator: "；")
        switch i.verdict {
        case .insufficientData, .mixed: break
        case .allNormal: out.append(DiagnosticEvidence(code: .allInterfacesNormal, statement: "所有網路類型皆正常（\(groupText)）"))
        case .allDegraded: out.append(DiagnosticEvidence(code: .allInterfacesDegraded, statement: "所有網路類型皆異常（\(groupText)）"))
        case .wifiNormalCellularDegraded:
            out.append(DiagnosticEvidence(code: .wifiNormalCellularDegraded, statement: "Wi-Fi 正常、行動網路異常（\(groupText)）"))
        case .allCellularDegradedWifiNormal:
            out.append(DiagnosticEvidence(code: .wifiNormalCellularDegraded, statement: "Wi-Fi 正常、行動網路異常（\(groupText)）"))
            out.append(DiagnosticEvidence(code: .allCellularDegradedWifiNormal, statement: "LTE 與 5G 皆異常，Wi-Fi 正常"))
        case .cellularNormalWifiDegraded:
            out.append(DiagnosticEvidence(code: .cellularNormalWifiDegraded, statement: "行動網路正常、Wi-Fi 異常（\(groupText)）"))
        }
        if i.verdict != .insufficientData { measured.insert(.interfaceCompare) }
        switch i.radioVerdict {
        case .insufficientData: break
        case .lteNormalNRDegraded: out.append(DiagnosticEvidence(code: .lteNormalNRDegraded, statement: "LTE 正常、5G 異常"))
        case .nrNormalLTEDegraded: out.append(DiagnosticEvidence(code: .nrNormalLTEDegraded, statement: "5G 正常、LTE 異常"))
        case .bothNormal, .bothDegraded: break
        }
        if i.radioVerdict != .insufficientData { measured.insert(.radioCompare) }
        return out
    }
}
