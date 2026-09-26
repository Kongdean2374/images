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
/// | noConfirmedGeneralLoss | < 0.5 % with ≥ 20 probes (scoped to the probed target)      |
/// | lossHigh / Severe      | > 2 % / > 5 %                                               |
/// | lossBursty / Random    | pattern burst|mixed with burst loss ≥ 0.5 % / pattern random |
/// | latencySpikesFrequent  | ≥ 3 spikes                                                  |
/// | *Bufferbloat           | loaded − idle median > 100 ms; noBufferbloat: all < 30 ms   |
/// | dnsSlow / Failures     | system median > 100 ms or > best + 30 ms / ≥ 20 % failures  |
/// | systemDNSHealthy       | system resolver median fine, failures < 20 % (scoped fact)  |
/// | dnsHighTailLatencyObserved | system P95 ≥ 150 ms and ≥ 3 × median                    |
/// | alternateIPv6ResolverDegraded | IPv6 alternate resolver ≥ 10 % failures or P95 ≥ 200 ms |
/// | loadedLatencyInflationObserved | loaded − idle ≥ 30 ms on a valid load                |
/// | tcpConnectSlow / tlsSlow / ttfbSlow | > 150 / > 250 / TTFB − TCP − TLS > 300 ms      |
/// | http3Negotiated        | an HTTP response actually used h3                           |
/// | quicReachable          | a QUIC handshake completed (says nothing about HTTP/3)      |
/// | quicBlocked            | QUIC failed while HTTP worked, server known to support h3   |
/// | mtuReduced / Normal    | path MTU < 1400 / ≥ 1400                                    |
public struct EvidenceExtractor: Sendable {
    public var crossTestAnalyzer: CrossTestAnalyzer
    public var anomalyDetector: AnomalyDetector
    /// Loaded − idle latency at which the rise is reported as a measured condition.
    public static let loadedInflationThresholdMs = 30.0

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
        var crossFacts = crossEvidence(cross, measured: &measured)
        // Latency probes of other endpoints can't vouch for a server whose transfer was invalid.
        if evidence.contains(where: { $0.code == .serverTransferInvalid }) {
            crossFacts.removeAll { $0.code == .allServersNormal }
        }
        evidence += crossFacts

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
                } else if c.anomalies.isEmpty && !c.sufficientForMatch {
                    // A baseline that shares < 2 metrics with this test can't vouch for "normal".
                    evidence.append(DiagnosticEvidence(code: .noBaseline, statement: "\(test.label)：歷史基準與本次測試可比較的指標不足（\(c.comparedMetrics?.count ?? 0) 項），不判定是否一致",
                                                       testIDs: [test.id], interface: iface))
                } else if c.anomalies.isEmpty, let b = c.baseline {
                    measured.insert(.baseline)
                    let list = (c.comparedMetrics ?? []).map(\.rawValue).joined(separator: ",")
                    evidence.append(DiagnosticEvidence(code: .matchesBaseline,
                                                       statement: "\(test.label)：結果與此裝置歷史基準一致（\(b.matchingCriteria)，\(b.sampleCount) 筆，比較指標 \(list)）",
                                                       value: Double(b.sampleCount), unit: "samples", testIDs: [test.id], interface: iface))
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
        if results.contains(where: { $0.crossValidation != nil || $0.serverRuns != nil }) || Set(results.compactMap { $0.server?.id }).count >= 2 {
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
        if results.contains(where: { $0.traceroute != nil }) { attempted.insert(.route) }
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
        if let st = r.stress {
            // Health checks and throughput validity are separate facts.
            let checked = st.nodes.filter { $0.healthy != nil }
            if !checked.isEmpty && checked.allSatisfy({ $0.healthy == true }) {
                add(.allServerHealthChecksPassed, "\(checked.count) 個節點健康檢查全部通過（僅代表可連線，不代表吞吐量測試成功）")
            }
            for t in st.invalidTransfers() {
                let name = st.nodes.first { $0.id == t.nodeID }?.name ?? t.nodeID
                let recovered = st.transfers.contains { $0.nodeID == t.nodeID && $0.round == t.round && $0.direction == t.direction && $0.isValid }
                add(.serverTransferInvalid,
                    "\(name) 第 \(t.round) 輪\(t.direction == .download ? "下載" : "上傳")第 \(t.attempt ?? 1) 次傳輸無效（\(t.validity?.reason?.rawValue ?? "invalid")：\(t.validity?.detail ?? "")）"
                        + (recovered ? "，重試後正常" : "，未能以重試排除"), Double(t.bytes), "bytes")
            }
            // Stress: only multi-probe (control) loss counts; the 50 pps ICMP probe alone never does.
            let lc = st.lossConfirmation
            let stressText = lc.stressLossPercent.map { "50 pps ICMP 壓力探測 \(Fmt.d($0, 1))%" } ?? "無 50 pps 壓力探測"
            let controlText = "\(lc.validControlCount) 個低頻對照探測中位數 \(lc.confirmedLossPercent.map { Fmt.d($0, 2) } ?? "—")%"
            let affected = (lc.affectedTargets ?? []).joined(separator: "、")
            let clean = (lc.cleanTargets ?? []).joined(separator: "、")
            switch lc.verdict {
            case .confirmedLoss, .confirmedGeneralPacketLoss:
                measured.insert(.loss)
                let v = lc.confirmedLossPercent ?? 0
                if v > 5 { add(.lossSevere, "已確認封包遺失 \(Fmt.d(v, 1))%（> 5%；\(controlText)，\(lc.lossyControlCount) 個探測皆遺失）", v, "%") }
                if v > 2 { add(.lossHigh, "已確認封包遺失 \(Fmt.d(v, 1))%（\(controlText)）", v, "%") }
            case .possibleICMPRateLimiting:
                measured.insert(.loss)
                add(.possibleICMPRateLimiting, "Possible ICMP rate limiting under stress：\(stressText)，但\(controlText)", lc.stressLossPercent, "%")
                add(.noConfirmedGeneralLoss, "低頻對照探測未遺失：無廣泛性封包遺失證據（\(controlText)）", lc.confirmedLossPercent, "%")
            case .endpointSpecificLossObserved:
                measured.insert(.loss)
                let worst = st.controlProbes.filter { (lc.affectedTargets ?? []).contains($0.target) }.map(\.lossPercent).max()
                add(.endpointSpecificLossObserved, "僅 \(affected) 觀察到封包遺失（\(stressText)）；獨立對照端點 \(clean) 無遺失 — 端點特定，非廣泛性遺失；高頻 ICMP 遺失可能包含 ICMP 限速",
                    worst ?? lc.stressLossPercent, "%")
                add(.noConfirmedGeneralLoss, "獨立對照端點 \(clean) 無遺失：無廣泛性封包遺失證據（\(controlText)）", lc.confirmedLossPercent, "%")
                if let e = st.elevatedAffectedEndpoints {
                    let list = e.endpoints.map { "\($0.target) \(Fmt.d($0.medianMs, 0)) ms" }.joined(separator: "、")
                    add(.endpointLatencyElevatedVsPeers, "遺失端點延遲亦明顯高於獨立對照端點（\(list)，對照中位數 \(Fmt.d(e.peerMedianMs, 0)) ms；同為低頻 ICMP；僅限這些位址，不代表同業者其他服務或 HTTP 路徑）",
                        e.endpoints.map { $0.medianMs }.max(), "ms")
                }
            case .noLoss, .noConfirmedGeneralPacketLoss:
                measured.insert(.loss)
                add(.noConfirmedGeneralLoss, "壓力與對照探測皆未觀察到遺失：無廣泛性封包遺失證據（\(stressText)；\(controlText)）", lc.confirmedLossPercent, "%")
            case .inconclusive:
                break
            }
            if let d = st.recoveryDeltaMs, d > StressSummary.slowRecoveryMs {
                add(.slowPostLoadRecovery, "負載停止後延遲仍高於負載前 \(Fmt.d(d, 0)) ms（佇列排空慢）", d, "ms")
            }
            for agg in [st.downloadAggregate, st.uploadAggregate].compactMap({ $0 }) where agg.values.count >= 2 {
                measured.insert(.crossServer)
                let dir = agg.direction == .download ? "下載" : "上傳"
                let list = agg.values.map { "\($0.name) \(Fmt.d($0.mbps, 0))" }.joined(separator: "、")
                if !agg.comparable {
                    // Different provider / protocol / stream count: only a range, never "consistent".
                    let methods = agg.values.map { "\($0.name) \(Fmt.d($0.mbps, 0)) Mbps（\($0.method ?? "?")）" }.joined(separator: "、")
                    if agg.minMbps > 0 && agg.maxMbps / agg.minMbps >= CrossProviderAggregate.methodDifferenceRatio {
                        add(.methodDependentThroughputDifference, "\(dir)速度差異取決於測試方法（不同業者 / 協定 / 連線數，不可直接比較）：\(methods)",
                            agg.maxMbps / agg.minMbps, "×")
                    } else {
                        add(.crossProviderObservedRange, "\(dir)觀察範圍 \(Fmt.d(agg.minMbps, 0))–\(Fmt.d(agg.maxMbps, 0)) Mbps（方法不等價，僅供參考）：\(methods)")
                    }
                } else if agg.largeVariance {
                    add(.largeCrossProviderThroughputVariance, "Large cross-provider throughput variance：\(dir) CV \(Fmt.d(agg.coefficientOfVariation ?? 0, 2))（\(list) Mbps）",
                        agg.coefficientOfVariation, "CV")
                } else {
                    add(.crossProviderThroughputConsistent, "跨業者\(dir)速度一致（CV \(Fmt.d(agg.coefficientOfVariation ?? 0, 2))；\(list) Mbps）",
                        agg.coefficientOfVariation, "CV")
                }
            }
            if let deg = st.throughputDegradationPercent, deg >= StressSummary.degradationPercent {
                add(.throughputDegradationUnderLoad, "持續負載後下載下降 \(Fmt.d(deg, 0))%（第 1 輪 → 第 \(st.plan.rounds) 輪）", deg, "%")
            }
        } else if let loss = lossStats?.loss, loss.sent > 0 {
            measured.insert(.loss)
            let method = r.packetLossMethod.map { "，\($0)" } ?? ""
            if loss.lossPercent > 5 { add(.lossSevere, "封包遺失 \(Fmt.d(loss.lossPercent, 1))%（> 5%\(method)）", loss.lossPercent, "%") }
            if loss.lossPercent > 2 { add(.lossHigh, "封包遺失 \(Fmt.d(loss.lossPercent, 1))%（\(loss.lost)/\(loss.sent)\(method)）", loss.lossPercent, "%") }
            if loss.lossPercent < 0.5 && loss.sent >= 20 {
                // One probe target clean ≠ "no loss anywhere": scoped to the probed path.
                add(.noConfirmedGeneralLoss, "受測路徑封包遺失 \(Fmt.d(loss.lossPercent, 2))%（\(loss.sent) 個探測；僅代表此目標，未確認其他路徑）", loss.lossPercent, "%")
            }
            if (loss.pattern == .burst || loss.pattern == .mixed) && loss.burstLossPercent >= 0.5 {
                add(.lossBursty, "連續遺失 \(loss.burstEvents) 次，最長 \(loss.longestBurst) 個封包（burst \(Fmt.d(loss.burstLossPercent, 1))%）", loss.burstLossPercent, "%")
            } else if loss.pattern == .random {
                add(.lossRandom, "遺失為零星隨機型（\(loss.randomLossEvents) 次）", loss.randomLossPercent, "%")
            }
        }

        // Bufferbloat — only a comparable idle / loaded pair (same probe method, fixed target not
        // under load) is a measured condition; anything else is indicative (comparisonQuality=limited).
        let dlBloat = m.downloadBloatMs, ulBloat = m.uploadBloatMs
        let comparisons = r.stress.map { st in TransferDirection.allCases.compactMap { st.bufferbloatComparison($0) } } ?? []
        let limited = comparisons.contains { $0.quality == .limited }
        if dlBloat != nil || ulBloat != nil {
            measured.insert(.bufferbloat)
            let worst = [dlBloat, ulBloat].compactMap { $0 }.max() ?? 0
            let parts = [dlBloat.map { "下載 +\(Fmt.d($0, 0))" }, ulBloat.map { "上傳 +\(Fmt.d($0, 0))" }].compactMap { $0 }.joined(separator: " / ")
            if limited {
                if worst >= Self.loadedInflationThresholdMs {
                    let why = comparisons.first { $0.quality == .limited }?.note ?? "comparisonQuality=limited"
                    add(.loadedLatencyRiseLimitedComparison, "負載時延遲上升（\(parts) ms），但閒置與負載量測不可完全比較：\(why)", worst, "ms")
                }
            } else {
                let probe = comparisons.first.map { "；探測 \($0.probe.method) → \($0.probe.target)" } ?? ""
                if let v = dlBloat, v > 100 { add(.downloadBufferbloat, "下載時延遲增加 \(Fmt.d(v, 0)) ms", v, "ms") }
                if let v = ulBloat, v > 100 { add(.uploadBufferbloat, "上傳時延遲增加 \(Fmt.d(v, 0)) ms", v, "ms") }
                if worst >= Self.loadedInflationThresholdMs {
                    add(.loadedLatencyInflationObserved, "負載時延遲上升（\(parts) ms，queue_location=unknown\(probe)）", worst, "ms")
                }
                if [dlBloat, ulBloat].compactMap({ $0 }).allSatisfy({ $0 < 30 }) {
                    add(.noBufferbloat, "滿載時延遲增加 < 30 ms（下載 \(dlBloat.map { Fmt.d($0, 0) } ?? "—") / 上傳 \(ulBloat.map { Fmt.d($0, 0) } ?? "—") ms\(probe)）")
                }
            }
        }

        // DNS
        if let dns = r.dns, let system = dns.resolvers.first(where: { $0.resolver.transport == .system }) {
            measured.insert(.dns)
            let failureRate = system.statistics.loss.lossPercent
            if failureRate >= 20 {
                add(.dnsFailures, "系統 DNS 失敗率 \(Fmt.d(failureRate, 0))%", failureRate, "%")
            }
            if let rtt = system.statistics.rtt {
                let sys = rtt.median
                // A tail caused by domains that were slow on several resolvers is a domain-specific cold
                // lookup, not resolver tail latency.
                let adjusted = DNSAnalyzer.systemStatsExcludingOutliers(dns)?.rtt
                if DNSTail.isHigh(median: sys, p95: rtt.p95) && adjusted.map({ DNSTail.isHigh(median: $0.median, p95: $0.p95) }) != false {
                    add(.dnsHighTailLatencyObserved, "系統 DNS P95 \(Fmt.d(rtt.p95, 0)) ms（中位數 \(Fmt.d(sys, 0)) ms）：dnsHighTailLatencyObserved，偶有查詢特別慢",
                        rtt.p95, "ms")
                }
                if sys > 100 || (m.bestDNSMs.map { sys - $0 > 30 } ?? false) {
                    add(.dnsSlow, "系統 DNS 中位數 \(Fmt.d(sys, 0)) ms（最佳 \(m.bestDNSName ?? "—") \(m.bestDNSMs.map { Fmt.d($0, 0) } ?? "—") ms）", sys, "ms")
                } else if failureRate < 20 {
                    // Scoped: only the system resolver's median, only this path — not "DNS is fine".
                    add(.systemDNSHealthy, "系統 DNS 解析器中位數 \(Fmt.d(sys, 0)) ms、P95 \(Fmt.d(rtt.p95, 0)) ms，失敗率 \(Fmt.d(failureRate, 0))%（僅代表系統解析器）", sys, "ms")
                }
            }
        }
        if let dns = r.dns {
            for f in DNSAnalyzer.analyze(dns) {
                switch f.kind {
                case .domainSpecificOutlier, .domainSpecificSystemResolverOutlier, .domainSpecificResolverOutlier: add(.dnsDomainSpecificOutlier, f.detail)
                case .transportSpecificIssue: add(.dnsTransportSpecificIssue, f.detail)
                case .resolverWideDegradation, .ipv6DNSPathIssue: break   // covered by dnsSlow / dnsFailures / alternateIPv6ResolverDegraded
                }
            }
        }
        // Alternate resolvers over IPv6: failures or a slow tail on that path, scoped to that resolver.
        for res in r.dns?.resolvers ?? [] where res.resolver.transport != .system && res.resolver.endpoint.contains(":") && !res.resolver.endpoint.contains("/") {
            let fail = res.statistics.loss.lossPercent
            let p95 = res.statistics.rtt?.p95
            if fail >= 10 || (p95 ?? 0) >= 200 {
                measured.insert(.dns)
                add(.alternateIPv6ResolverDegraded,
                    "\(res.resolver.name)（\(res.resolver.endpoint)）失敗 \(res.statistics.loss.lost)/\(res.statistics.sent)、P95 \(p95.map { Fmt.d($0, 0) } ?? "—") ms（僅此 IPv6 解析器路徑）",
                    p95, "ms")
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
            // quicReachable (UDP 443 + QUIC handshake) and http3Negotiated (an HTTP response over h3)
            // are separate facts: a handshake alone never claims HTTP/3.
            if probe.http3Negotiated {
                add(.http3Negotiated, "\(probe.host)：HTTP 請求實際協商為 HTTP/3（http3Negotiated）")
            } else if let fallback = probe.http3Attempt?.negotiatedProtocol {
                // URLSession may silently fall back to TCP: a non-h3 answer is inconclusive for HTTP/3.
                add(.http3FallbackObserved, "\(probe.host)：HTTP/3 請求退回 \(fallback.displayName)（TCP）— 無法據此判定 HTTP/3 成功或失敗")
            }
            let quicOK = (probe.quicProbes ?? []).filter { $0.handshakeMs != nil }
            let quicFailed = (probe.quicProbes ?? []).filter { $0.handshakeMs == nil }
            if !quicOK.isEmpty && !quicFailed.isEmpty {
                add(.endpointQuicHandshakeFailed, "QUIC 交握僅在特定端點失敗：\(quicFailed.map { "\($0.host)（\($0.failure?.rawValue ?? "failed")）" }.joined(separator: "、"))；"
                    + "其他端點成功：\(quicOK.map(\.host).joined(separator: "、"))（端點特定，非 UDP 封鎖）")
            }
            if probe.quicReachable {
                add(.quicReachable, "QUIC 交握成功（generalQuicReachable / udp443Reachable）\(quicOK.isEmpty ? "" : "：\(quicOK.map(\.host).joined(separator: "、"))")")
            } else if !probe.http3Negotiated, let assessment {
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

        // v3.0 stress phases — facts first; mechanisms / locations stay hypotheses.
        if let L = r.stressLoad {
            if let ramp = L.streamRamp {
                measured.insert(.throughput)
                if ramp.saturationDetected, let n = ramp.saturationStreamCount {
                    add(.saturationReached, "連線數階梯：約 \(n) 條連線後吞吐量不再明顯增加（\(Fmt.d(ramp.saturationThroughputMbps ?? 0, 0)) Mbps）", ramp.saturationThroughputMbps, "Mbps")
                }
                if let g = ramp.marginalGainPercent, g < StreamRampResult.plateauGainPercent {
                    add(.streamScalingPlateau, "最後一級連線數的增益僅 \(Fmt.d(g, 1))%：增加連線已無法提高吞吐量", g, "%")
                }
            }
            for s in [L.sustainedDownload, L.sustainedUpload].compactMap({ $0 }) {
                if let d = s.throughput?.degradationPercent, d >= 15 {
                    add(.sustainedThroughputDegradation, "持續\(s.direction == .download ? "下載" : "上傳") \(Fmt.d(s.plannedSeconds, 0)) 秒：結尾比開頭慢 \(Fmt.d(d, 0))%", d, "%")
                }
            }
            if let fd = L.fullDuplex {
                measured.insert(.throughput)
                let worst: Double? = [fd.downloadDegradationPercent, fd.uploadDegradationPercent].compactMap { $0 }.max()
                if let worst, worst >= 25 {
                    add(.fullDuplexInterference, "上下行同時滿載：下載降 \(Fmt.d(fd.downloadDegradationPercent ?? 0, 0))%、上傳降 \(Fmt.d(fd.uploadDegradationPercent ?? 0, 0))%（相對單向，同節點同方法）", worst, "%")
                }
            }
            let inflations: [Double] = [L.sustainedDownload?.latency?.inflationMs, L.sustainedUpload?.latency?.inflationMs, L.fullDuplex?.latency?.inflationMs].compactMap { $0 }
            if let w = inflations.max(), w >= Self.loadedInflationThresholdMs {
                measured.insert(.bufferbloat)
                add(.loadCorrelatedLatencyInflation, "負載時控制延遲上升 \(Fmt.d(w, 0)) ms（同一固定目標與方法：\(L.monitor?.probe.target ?? "control")；佇列位置未知）", w, "ms")
            }
            let idleSamples: [MonitorSample] = (L.monitor?.samples ?? []).filter { $0.loadType == .idle }
            let idleLost: Int = idleSamples.filter { $0.rttMs == nil }.count
            let idleLoss: Double = idleSamples.isEmpty ? 0 : Double(idleLost) / Double(idleSamples.count) * 100
            let lossCandidates: [Double?] = [L.sustainedDownload?.latency?.lossPercent, L.sustainedUpload?.latency?.lossPercent, L.fullDuplex?.latency?.lossPercent]
            let loadLoss: Double? = lossCandidates.compactMap { $0 }.max()
            if let loadLoss, loadLoss >= 1, idleLoss < 0.5 {
                add(.loadCorrelatedLoss, "負載時控制探測遺失 \(Fmt.d(loadLoss, 1))%，閒置時 \(Fmt.d(idleLoss, 1))%（同一探測）", loadLoss, "%")
            }
            if let bu = L.burst {
                if let m = bu.medianRecoveryTimeMs, m > 1000 { add(.burstRecoverySlow, "突發負載結束後延遲恢復中位數 \(Fmt.d(m, 0)) ms", m, "ms") }
                if let l = bu.lossPercent, l >= 1, idleLoss < 0.5 { add(.burstTriggeredLoss, "突發負載期間控制探測遺失 \(Fmt.d(l, 1))%", l, "%") }
            }
            if let md = L.multiDestination, md.singleDestinationLimitationPossible {
                add(.multiDestinationHigherAggregate, "多目的地總和 \(Fmt.d(md.aggregateMbps, 0)) Mbps 高於單一目的地 \(Fmt.d(md.bestSingleStandardMbps ?? 0, 0)) Mbps：單一目的地限制「可能」存在（方法不同，非供應商比較）", md.aggregateMbps, "Mbps")
            }
            if let f = L.finalRecovery, !f.complete {
                add(.postLoadRecoveryIncomplete, "最終恢復 \(Fmt.d(f.plannedSeconds, 0)) 秒內延遲未回到基準 ±10%")
            }
            if let env = L.environment, env.thermalRose {
                add(.thermalStateChangedDuringLoad, "壓力期間裝置溫度狀態 \(env.thermalStart ?? "?") → \(env.thermalPeak ?? "?")（僅為相關性，不代表網路因熱降速）")
            }
        }

        // MTU
        if let mtu = r.mtu?.pathMTU {
            measured.insert(.mtu)
            let target = r.mtu?.target ?? "目標"
            if mtu < 1400 { add(.mtuReduced, "IPv4 → \(target) 路徑 MTU \(mtu) bytes", Double(mtu), "bytes") }
            else {
                add(.pathMTUObserved, "observed_path_mtu_ipv4=\(mtu) bytes（僅 IPv4 → \(target) 這條路徑；mtu_blackhole_evidence=false；不代表其他目的地或 IPv6 路徑）",
                    Double(mtu), "bytes")
            }
        }

        // Route — an isolated slow hop is ICMP deprioritisation, only a persistent step is a path fact.
        if let tr = r.traceroute {
            let a = TracerouteAnalyzer.analyze(tr.hops)
            if a.sufficient {
                measured.insert(.route)
                if let step = a.largestStep {
                    add(.routeLatencyStep, "路由第 \(step.fromTTL) → \(step.toTTL) 跳延遲持續增加 \(Fmt.d(step.increaseMs, 0)) ms（之後各跳皆維持），為路徑本身的延遲",
                        step.increaseMs, "ms")
                }
                if !a.isolatedHighHops.isEmpty {
                    let list = a.isolatedHighHops.map { "#\($0.ttl) +\(Fmt.d($0.excessMs, 0)) ms" }.joined(separator: "、")
                    add(.intermediateHopICMPDeprioritized, "個別節點延遲偏高但後續節點較快（\(list)）：路由器對 ICMP 降低優先權，不代表壅塞")
                }
            }
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

    /// Entry methods that mean "a speed-test server measured by the test itself".
    static let serverMethods: Set<String> = ["speed test", "multi-server"]

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
            out.append(DiagnosticEvidence(code: .allServersNormal, statement: "\(total) 個獨立伺服器 / 端點的延遲與遺失皆正常（延遲探測，不含吞吐量）\(measuredNote)"))
        case .singleServerAnomalous:
            // An independent validation endpoint (e.g. 1.1.1.1 over ICMP) is not the speed-test
            // server: its behaviour is endpoint-specific, never evidence about the test server / route.
            let anomalous = s.entries.first(where: \.isAnomalous)
            if let a = anomalous, !Self.serverMethods.contains(a.method) {
                out.append(DiagnosticEvidence(code: .endpointSpecificBehaviorObserved,
                    statement: "僅獨立驗證端點 \(a.name)（\(a.method)）與其他端點不同：\(a.reasons.joined(separator: "、"))；只限此位址與此探測方式，不代表測速伺服器或同業者其他服務異常"))
            } else {
                out.append(DiagnosticEvidence(code: .singleServerAnomalous, statement: "僅 1 個伺服器異常：\(anomalousNames.joined(separator: "；"))，其他 \(total - 1) 個正常"))
            }
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
