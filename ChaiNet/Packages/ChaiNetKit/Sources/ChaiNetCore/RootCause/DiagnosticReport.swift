import Foundation

/// Flattened key statistics of one test (one row of the report's statistics table).
public struct TestStatisticsRow: Codable, Sendable, Hashable {
    public var testID: UUID
    public var label: String
    public var network: String
    public var server: String?
    public var ipFamily: String
    public var download: SpeedSummary?
    public var upload: SpeedSummary?
    public var idleLatency: RTTSummary?
    public var downloadLoadedLatency: RTTSummary?
    public var uploadLoadedLatency: RTTSummary?
    public var loss: LossAnalysis?
    public var lossMethod: String?
    public var bufferbloat: BufferbloatResult?
    public var scores: QualityScores
    public var health: TestHealthAssessment
}

public struct TestEnvironment: Codable, Sendable, Hashable {
    public var testID: UUID
    public var label: String
    public var date: Date
    public var networkClass: NetworkClass
    public var network: NetworkSnapshot
    public var server: ServerDescriptor?
    public var serverInfo: ServerInfo?
    public var serverHealth: ServerHealth?
    public var ipFamilyPreference: IPFamilyPreference
}

public struct ReportMetadata: Codable, Sendable, Hashable {
    public var schema: String
    public var version: Int
    public var generatedAt: Date
    public var appVersion: String
    public var platform: String
    public var privacyNote: String
}

/// The full technical report. JSON keeps every raw sample so a human or an AI can re-analyse it.
public struct DiagnosticReport: Codable, Sendable, Hashable {
    public var metadata: ReportMetadata
    public var sessionID: UUID
    public var sessionTitle: String
    public var sessionCreatedAt: Date
    public var symptom: TroubleshootingSymptom?
    public var summary: String
    public var environment: [TestEnvironment]
    public var statistics: [TestStatisticsRow]
    public var timeline: [TimelineEvent]
    public var anomalies: [BaselineAnomaly]
    public var crossTest: CrossTestReport?
    public var analysis: RootCauseAnalysis
    public var platformLimitations: [String]
    /// Raw measurements (full timelines).
    public var rawTests: [SessionTest]
}

public protocol DiagnosticReportGenerating: Sendable {
    func makeReport(session: DiagnosticSession, analysis: RootCauseAnalysis, appVersion: String, platform: String, includeLocation: Bool) -> DiagnosticReport
    func json(_ report: DiagnosticReport) throws -> Data
    func text(_ report: DiagnosticReport) -> String
}

public struct DiagnosticReportGenerator: DiagnosticReportGenerating {
    public static let schema = "chainet.diagnostic-report"
    public static let version = 1

    public var anomalyDetector: AnomalyDetector

    public init(anomalyDetector: AnomalyDetector = AnomalyDetector()) {
        self.anomalyDetector = anomalyDetector
    }

    public static let platformLimitations = [
        "iOS 不提供行動網路訊號資訊（RSRP、RSRQ、SINR、NR 頻段、Cell ID），報告中標示為 unavailable，未做任何模擬。",
        "5G NSA / SA 與 LTE 僅來自 CoreTelephony 的無線電制式（Radio Access Technology）字串。",
        "iOS 不提供 Wi-Fi RSSI / 雜訊 / 頻道；SSID 需要特殊授權，未簽名版本無法取得。",
        "VPN 偵測為啟發式（介面名稱與系統 Proxy 設定），iOS 沒有公開 API。",
        "路由追蹤與 MTU 測試使用 ICMP datagram socket，目前僅支援 IPv4，且部分網路會過濾 ICMP。",
        "App 無法強制切換 LTE / 5G；跨制式比較需由使用者在系統設定中切換後再加入同一工作階段。",
        "iOS 背景執行受限，連續監測需保持 App 在前景；背景僅能由系統排程進行短暫檢查。",
    ]

    public func makeReport(session: DiagnosticSession, analysis: RootCauseAnalysis, appVersion: String, platform: String,
                           includeLocation: Bool = false) -> DiagnosticReport {
        var tests = session.tests
        if !includeLocation {
            for i in tests.indices { tests[i].result.location = nil }
        }
        let env = tests.map { t in
            TestEnvironment(testID: t.id, label: t.label, date: t.result.date, networkClass: t.networkClass, network: t.result.network,
                            server: t.result.server, serverInfo: t.result.serverInfo, serverHealth: t.result.serverHealth,
                            ipFamilyPreference: t.result.ipFamilyPreference)
        }
        let rows = tests.map { t -> TestStatisticsRow in
            let r = t.result
            let latency = r.idleLatency ?? r.gaming?.idle ?? r.voice?.latency ?? r.monitoring?.statistics
            let lossStats = r.packetLoss ?? latency
            return TestStatisticsRow(testID: t.id, label: t.label, network: t.networkClass.displayName, server: r.server?.name,
                                     ipFamily: r.ipFamilyPreference.displayName,
                                     download: (r.download ?? r.streaming?.download)?.summary, upload: (r.upload ?? r.obs?.upload)?.summary,
                                     idleLatency: latency?.rtt, downloadLoadedLatency: r.downloadLoadedLatency?.rtt,
                                     uploadLoadedLatency: r.uploadLoadedLatency?.rtt,
                                     loss: lossStats.flatMap { $0.sent > 0 ? $0.loss : nil }, lossMethod: r.packetLossMethod,
                                     bufferbloat: r.bufferbloat, scores: r.scores, health: TestHealthEvaluator.assess(r))
        }
        let timeline = tests.flatMap { anomalyDetector.timelineEvents($0.result) }
        let anomalies = analysis.evidence.baselineComparisons.flatMap(\.anomalies)
        let top = analysis.mostLikely
        let summary = top.map { "\(session.tests.count) 項測試。最可能原因：\($0.title)（信心 \($0.confidencePercent)%）。" }
            ?? "\(session.tests.count) 項測試。未找到信心足夠的單一原因。"

        return DiagnosticReport(
            metadata: ReportMetadata(schema: Self.schema, version: Self.version, generatedAt: Date(), appVersion: appVersion, platform: platform,
                                     privacyNote: includeLocation ? "包含使用者同意匯出的位置資料。" : "不含位置資料。"),
            sessionID: session.id, sessionTitle: session.title, sessionCreatedAt: session.createdAt, symptom: session.symptom,
            summary: summary, environment: env, statistics: rows, timeline: timeline, anomalies: anomalies,
            crossTest: analysis.evidence.crossTest, analysis: analysis, platformLimitations: Self.platformLimitations, rawTests: tests)
    }

    public func json(_ report: DiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    public static func decode(_ data: Data) throws -> DiagnosticReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticReport.self, from: data)
    }

    // MARK: Plain text

    /// Plain-text report designed to be pasted into an AI assistant or a support ticket.
    /// Every value carries its unit; unavailable data is written as "unavailable" with the reason.
    public func text(_ report: DiagnosticReport) -> String {
        var out: [String] = []
        let iso = ISO8601DateFormatter()
        func h(_ title: String) { out.append(""); out.append("## \(title)") }
        func v(_ x: Double?, _ d: Int = 1, _ unit: String = "") -> String {
            guard let x, x.isFinite else { return "n/a" }
            return Fmt.d(x, d) + (unit.isEmpty ? "" : " \(unit)")
        }
        func avail<T: Codable & Sendable & Hashable>(_ a: Availability<T>, _ f: (T) -> String) -> String {
            switch a {
            case .available(let x): f(x)
            case .unavailable(let reason): "unavailable（\(reason)）"
            }
        }

        out.append("ChaiNet Diagnostic Report v\(report.metadata.version)")
        out.append("schema: \(report.metadata.schema) · generated: \(iso.string(from: report.metadata.generatedAt)) · app: \(report.metadata.appVersion) · \(report.metadata.platform)")
        out.append("session: \(report.sessionTitle) (\(report.sessionID.uuidString)) · created: \(iso.string(from: report.sessionCreatedAt))")
        if let s = report.symptom { out.append("reported symptom: \(s.displayName)") }
        out.append("privacy: \(report.metadata.privacyNote)")

        h("1. Session summary")
        out.append(report.summary)

        h("2. Environment")
        for e in report.environment {
            let n = e.network
            out.append("[\(e.label)] \(iso.string(from: e.date)) · network=\(e.networkClass.displayName) · interface=\(n.primaryInterface.rawValue) · status=\(n.status.rawValue)")
            out.append("  expensive=\(n.isExpensive) constrained(lowDataMode)=\(n.isConstrained) ipv4=\(n.supportsIPv4) ipv6=\(n.supportsIPv6) dns=\(n.supportsDNS) ipPreference=\(e.ipFamilyPreference.rawValue)")
            out.append("  vpn=\(n.vpn.state.rawValue) interfaces=\(n.vpn.interfaces.joined(separator: ",")) method=\(n.vpn.method)")
            if let c = n.cellular {
                out.append("  cellular: rat=\(avail(c.radioTechnology) { "\($0.rawValue) (\($0.generationLabel))" }) carrier=\(avail(c.carrierName) { $0 })")
                out.append("  cellular signal: band=\(avail(c.signal.band) { $0 }) rsrp=\(avail(c.signal.rsrp) { v($0, 0, "dBm") }) rsrq=\(avail(c.signal.rsrq) { v($0, 0, "dB") }) sinr=\(avail(c.signal.sinr) { v($0, 0, "dB") }) cellID=\(avail(c.signal.cellID) { $0 })")
            }
            if let w = n.wifi {
                out.append("  wifi: ssid=\(avail(w.ssid) { $0 }) rssi=\(avail(w.rssi) { v($0, 0, "dBm") })")
            }
            if let s = e.server { out.append("  server: \(s.name) · \(s.location) · \(s.baseURL.absoluteString) · kind=\(s.kind.rawValue)") }
            if let h = e.serverHealth { out.append("  serverHealth: reachable=\(h.reachable) healthy=\(h.healthy) response=\(v(h.responseMs, 0, "ms"))") }
        }

        h("3. Statistics")
        for r in report.statistics {
            out.append("[\(r.label)] \(r.network) · server=\(r.server ?? "n/a") · ip=\(r.ipFamily) · degraded=\(r.health.isDegraded)\(r.health.reasons.isEmpty ? "" : " (\(r.health.reasons.joined(separator: ", ")))")")
            for (name, s) in [("download", r.download), ("upload", r.upload)] {
                guard let s else { out.append("  \(name): not measured"); continue }
                out.append("  \(name): avg=\(v(s.averageMbps, 2, "Mbps")) peak=\(v(s.peakMbps, 2)) min=\(v(s.minimumMbps, 2)) median=\(v(s.medianMbps, 2)) p95=\(v(s.p95Mbps, 2)) p10=\(v(s.p10Mbps, 2)) stability=\(v(s.stability.score, 0, "%")) cv=\(v(s.stability.coefficientOfVariation, 3)) drops=\(s.stability.dropCount) bytes=\(s.totalBytes) duration=\(v(s.duration, 1, "s"))")
                out.append("    method: \(s.methodDescription)")
                if let windows = s.analysisWindowMbps {
                    out.append("    statistics windows (Mbps, basis of median/p95/p10/min/peak/stability): " + windows.map { Fmt.d($0, 1) }.joined(separator: " "))
                }
            }
            for (name, l) in [("idle latency", r.idleLatency), ("download-loaded latency", r.downloadLoadedLatency), ("upload-loaded latency", r.uploadLoadedLatency)] {
                guard let l else { out.append("  \(name): not measured"); continue }
                out.append("  \(name): min=\(v(l.minimum)) avg=\(v(l.average)) median=\(v(l.median)) max=\(v(l.maximum)) p95=\(v(l.p95)) p99=\(v(l.p99)) jitter=\(v(l.jitter)) jitterRFC3550=\(v(l.jitterRFC3550)) sd=\(v(l.standardDeviation)) (ms)")
            }
            if let loss = r.loss {
                out.append("  packet loss (\(r.lossMethod ?? "latency probe")): \(loss.lost)/\(loss.sent) = \(v(loss.lossPercent, 2, "%")) random=\(v(loss.randomLossPercent, 2, "%")) burst=\(v(loss.burstLossPercent, 2, "%")) burstEvents=\(loss.burstEvents) longestBurst=\(loss.longestBurst) pattern=\(loss.pattern.rawValue) p=\(v(loss.lossProbabilityAfterReceive, 3)) r=\(v(loss.recoveryProbabilityAfterLoss, 3))")
            } else {
                out.append("  packet loss: not measured")
            }
            if let b = r.bufferbloat {
                out.append("  bufferbloat: grade=\(b.grade.rawValue) idleMedian=\(v(b.idleMedianMs)) dlLoaded=\(v(b.downloadLoadedMedianMs)) (+\(v(b.downloadIncreaseMs))) ulLoaded=\(v(b.uploadLoadedMedianMs)) (+\(v(b.uploadIncreaseMs))) ms")
            }
            let sc = r.scores
            out.append("  scores: overall=\(sc.overall.map(String.init) ?? "n/a") gaming=\(sc.gaming.map(String.init) ?? "n/a") streaming=\(sc.streaming.map(String.init) ?? "n/a") voice=\(sc.voice.map(String.init) ?? "n/a") upload=\(sc.upload.map(String.init) ?? "n/a")")
        }

        h("4. Raw measurements")
        for t in report.rawTests {
            let r = t.result
            for speed in [r.download, r.upload].compactMap({ $0 }) {
                // 0.5 s buckets keep the text compact; the JSON export has every 100 ms sample.
                let buckets = Dictionary(grouping: speed.samples) { Int(($0.offset - 0.0001) / 0.5) }
                let series = buckets.keys.sorted().map { k -> String in
                    let s = buckets[k]!
                    let mbps = SpeedMath.mbps(bytes: s.reduce(0) { $0 + $1.intervalBytes }, seconds: s.reduce(0) { $0 + $1.intervalDuration })
                    return Fmt.d(mbps, 1)
                }
                out.append("[\(t.label)] \(speed.direction.rawValue) Mbps per 0.5 s clock bucket (ALL samples incl. warm-up / stream transitions; display aggregation, NOT the statistics basis — see statistics windows in section 3): \(series.joined(separator: " "))")
                if !speed.streamChanges.isEmpty {
                    out.append("[\(t.label)] \(speed.direction.rawValue) parallel streams: " + speed.streamChanges.map { "\(Fmt.d($0.offset, 1))s→\($0.streams)" }.joined(separator: ", "))
                }
            }
            if let samples = r.idleSamples, !samples.isEmpty {
                out.append("[\(t.label)] idle RTT ms (* = lost): " + samples.sorted { $0.sequence < $1.sequence }.map { $0.rttMs.map { Fmt.d($0, 1) } ?? "*" }.joined(separator: " "))
            }
            if let mon = r.monitoring {
                out.append("[\(t.label)] monitoring \(mon.target) every \(Fmt.d(mon.intervalSeconds, 1)) s, \(mon.samples.count) probes: " +
                           mon.samples.suffix(300).map { $0.rttMs.map { Fmt.d($0, 0) } ?? "*" }.joined(separator: " "))
            }
            if let dns = r.dns {
                for res in dns.ranked {
                    out.append("[\(t.label)] dns \(res.resolver.name) (\(res.resolver.transport.rawValue)): median=\(v(res.statistics.rtt?.median)) p95=\(v(res.statistics.rtt?.p95)) failures=\(res.statistics.loss.lost)/\(res.statistics.sent) ms")
                }
            }
            if let p = r.protocolProbe, let http = p.http {
                out.append("[\(t.label)] http: proto=\(http.negotiatedProtocol.rawValue) dns=\(v(http.dnsMs)) tcp=\(v(http.tcpConnectMs)) tls=\(v(http.tlsMs)) ttfb=\(v(http.ttfbMs)) total=\(v(http.totalMs)) ms tls=\(http.tlsVersion ?? "n/a") remote=\(http.remoteAddress ?? "n/a")")
                out.append("[\(t.label)] http3Attempt=\(p.http3Attempt?.negotiatedProtocol.rawValue ?? "n/a") quicHandshake(target)=\(avail(p.quicHandshakeMs) { v($0, 1, "ms") }) ipv4=\(avail(p.ipv4Reachable) { v($0, 1, "ms") }) ipv6=\(avail(p.ipv6Reachable) { v($0, 1, "ms") })")
                out.append("[\(t.label)] quic assessment=\((p.quicAssessment ?? .notTested).rawValue): " + (p.quicProbes ?? []).map {
                    "\($0.host) \($0.handshakeMs.map { v($0, 0, "ms") } ?? "fail(\($0.failure?.rawValue ?? "?"))") tcp443=\($0.tcpReachable.map { $0 ? "ok" : "fail" } ?? "n/a")"
                }.joined(separator: "; "))
            }
            if let c = r.ipFamilyComparison {
                out.append("[\(t.label)] ipv4 vs ipv6 (\(c.method.rawValue) → \(c.target)): v4 median=\(v(c.ipv4?.rtt?.median)) loss=\(v(c.ipv4?.loss.lossPercent, 1, "%")) err=\(c.ipv4Error ?? "-") · v6 median=\(v(c.ipv6?.rtt?.median)) loss=\(v(c.ipv6?.loss.lossPercent, 1, "%")) err=\(c.ipv6Error ?? "-")")
            }
            for run in r.serverRuns ?? [] {
                let lat = run.packetLoss ?? run.idleLatency
                out.append("[\(t.label)] multi-server \(run.server.name) [\(run.server.location)]: median=\(v(lat?.rtt?.median)) ms loss=\(v(lat?.loss.lossPercent, 2, "%")) jitter=\(v(lat?.rtt?.jitter)) ms download=\(v(run.download?.summary.averageMbps, 2, "Mbps")) upload=\(v(run.upload?.summary.averageMbps, 2, "Mbps"))\(run.error.map { " error=\($0)" } ?? "")")
            }
            for check in r.crossValidation ?? [] {
                out.append("[\(t.label)] cross-check \(check.name) [\(check.region)] \(check.method.rawValue): median=\(v(check.statistics?.rtt?.median)) ms loss=\(v(check.statistics?.loss.lossPercent, 1, "%")) err=\(check.error ?? "-")")
            }
            if let tr = r.traceroute {
                out.append("[\(t.label)] traceroute \(tr.target) (\(tr.resolvedAddress)): " + tr.hops.map { "\($0.ttl):\($0.address ?? "*")/\(v($0.bestMs, 0))" }.joined(separator: " "))
            }
            if let mtu = r.mtu { out.append("[\(t.label)] path MTU: \(mtu.pathMTU.map(String.init) ?? "n/a") bytes (\(mtu.method))") }
        }

        h("5. Timeline events")
        if report.timeline.isEmpty { out.append("none") }
        let labels = Dictionary(uniqueKeysWithValues: report.rawTests.map { ($0.id, $0.label) })
        for e in report.timeline {
            out.append("[\(labels[e.testID] ?? "?")] t=\(Fmt.d(e.offset, 1))s\(e.duration.map { " (\(Fmt.d($0, 1))s)" } ?? "") \(e.kind.rawValue): \(e.detail)")
        }

        h("6. Anomalies vs. historical baseline")
        if report.anomalies.isEmpty {
            out.append(report.analysis.evidence.baselineComparisons.contains { $0.baseline != nil } ? "none (results match baseline)" : "no baseline available yet")
        }
        for a in report.anomalies {
            out.append("[\(labels[a.testID] ?? "?")] \(a.severity.rawValue): \(a.summary) · robustZ=\(Fmt.d(a.robustZ, 1))")
        }

        h("7. Cross-test comparisons")
        if let c = report.crossTest {
            out.append("servers: verdict=\(c.servers.verdict.rawValue)\(c.servers.anomalousRegion.map { " anomalousRegion=\($0)" } ?? "")\(c.servers.throughputConsistent.map { " throughputConsistent=\($0)" } ?? "")")
            for e in c.servers.entries {
                out.append("  - \(e.name) [\(e.region)] via \(e.method): status=\(e.status.rawValue) median=\(v(e.latencyMedianMs)) ms loss=\(v(e.lossPercent, 1, "%")) jitter=\(v(e.jitterMs)) ms download=\(v(e.downloadMbps, 1, "Mbps")) endpointBaseline=\(v(e.baselineMedianMs)) ms higherLatencyRelativeToPeers=\(e.higherLatencyRelativeToPeers) \(e.reasons.joined(separator: ", "))\(e.unavailableReason.map { " unavailable: \($0)" } ?? "")")
            }
            let ip = c.ipFamilies
            out.append("ip families: verdict=\(ip.verdict.rawValue) v4=\(v(ip.ipv4MedianMs)) ms/\(v(ip.ipv4LossPercent, 1, "%")) v6=\(v(ip.ipv6MedianMs)) ms/\(v(ip.ipv6LossPercent, 1, "%"))")
            out.append("interfaces: verdict=\(c.interfaces.verdict.rawValue) radio=\(c.interfaces.radioVerdict.rawValue)")
            for g in c.interfaces.groups {
                out.append("  - \(g.networkClass.displayName): \(g.degraded ? "degraded" : "normal") (\(g.measuredCount) measured) \(g.reasons.joined(separator: ", "))")
            }
            for u in c.interfaces.unavailable {
                out.append("  - \(u.networkClass.displayName): NOT TESTED / unavailable (\(u.reason)) — excluded from verdicts")
            }
        }

        h("8. Evidence (observations — not conclusions)")
        for kind in [EvidenceKind.measured, .derived, .heuristic, .notTested] {
            let items = report.analysis.evidence.evidence.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            out.append("### \(kind.rawValue)（\(kind.displayName)）")
            for e in items { out.append("- [\(e.code.rawValue)] \(e.statement)") }
        }
        out.append("measured dimensions: " + report.analysis.evidence.measuredDimensions.map(\.rawValue).sorted().joined(separator: ", "))
        let unmeasured = EvidenceDimension.allCases.filter { !report.analysis.evidence.measuredDimensions.contains($0) }
        out.append("not measured: " + (unmeasured.isEmpty ? "none" : unmeasured.map(\.rawValue).joined(separator: ", ")))
        out.append("attempted but inconclusive: " + report.analysis.evidence.attemptedDimensions.subtracting(report.analysis.evidence.measuredDimensions)
            .map(\.rawValue).sorted().joined(separator: ", "))

        h("9. Diagnostic hypotheses")
        for group in [Likelihood.likely, .possible, .insufficientEvidence, .notTested, .unlikely] {
            let hs = report.analysis.hypotheses.filter { $0.likelihood == group }
            guard !hs.isEmpty else { continue }
            out.append("### \(group.displayName)")
            for hyp in hs {
                out.append("* \(hyp.title) — status: \(hyp.likelihood.rawValue) — confidence \(hyp.confidencePercent)% — layer: \(hyp.layer.displayName)")
                if let reason = hyp.statusReason { out.append("  status reason: \(reason)") }
                out.append("  why: \(hyp.explanation)")
                for e in hyp.supportingEvidence { out.append("  + \(e.statement)") }
                for e in hyp.contradictingEvidence { out.append("  − \(e.statement)") }
                if !hyp.missingDimensions.isEmpty { out.append("  missing data: " + hyp.missingDimensions.map(\.displayName).joined(separator: "、")) }
                if !hyp.recommendedNextTests.isEmpty { out.append("  verify: " + hyp.recommendedNextTests.map(\.title).joined(separator: "；")) }
                for l in hyp.limitations { out.append("  limitation: \(l)") }
            }
        }

        h("10. Ruled-out causes (decisive measured contradiction only; untested causes are listed under not tested)")
        let ruled = report.analysis.ruledOut
        if ruled.isEmpty { out.append("none") }
        for hyp in ruled {
            out.append("* \(hyp.title) — ruled out by: " + hyp.rulingOutEvidence.map(\.statement).joined(separator: "；"))
        }

        h("11. Suggested next tests")
        if report.analysis.recommendedTests.isEmpty { out.append("none") }
        for (i, t) in report.analysis.recommendedTests.enumerated() {
            out.append("\(i + 1). \(t.test.title) (priority \(Int((t.priority * 100).rounded()))) — \(t.test.howTo)")
            out.append("   helps with: " + t.reasons.joined(separator: "、"))
        }

        h("12. Technical conclusion")
        out.append(report.analysis.conclusion)

        h("13. Platform limitations")
        for l in report.platformLimitations { out.append("- \(l)") }

        h("14. Consistency check")
        let issues = ReportConsistencyValidator.validate(report)
        out.append(issues.isEmpty ? "passed (summary, statistics, raw measurements, evidence, hypotheses and ruled-out causes agree)"
                                  : issues.map { "FAILED: \($0)" }.joined(separator: "\n"))
        out.append("")
        out.append("— end of ChaiNet Diagnostic Report v\(report.metadata.version) —")
        return out.joined(separator: "\n")
    }
}
