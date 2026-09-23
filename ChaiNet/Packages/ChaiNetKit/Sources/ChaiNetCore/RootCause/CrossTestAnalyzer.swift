import Foundation

// MARK: - Output types

public struct ServerComparisonEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var region: String
    public var method: String
    public var latencyMedianMs: Double?
    public var lossPercent: Double?
    public var downloadMbps: Double?
    public var isAnomalous: Bool
    public var reasons: [String]
}

public enum ServerComparisonVerdict: String, Codable, Sendable, Hashable {
    case insufficientData, allNormal, singleServerAnomalous, multipleServersAnomalous, allServersAnomalous
}

public struct ServerComparison: Codable, Sendable, Hashable {
    public var entries: [ServerComparisonEntry]
    public var verdict: ServerComparisonVerdict
    /// Region containing all anomalous endpoints while endpoints elsewhere are normal.
    public var anomalousRegion: String?
    /// Servers whose download is < 50 % of the best server.
    public var throughputOutlierIDs: [String]
    /// True when ≥ 2 servers were speed-tested and all are within 50 % of the best.
    public var throughputConsistent: Bool?
}

public enum IPFamilyVerdict: String, Codable, Sendable, Hashable {
    case insufficientData, equivalent, ipv6Degraded, ipv4Degraded, bothDegraded, ipv6Unavailable
}

public struct IPFamilyComparison: Codable, Sendable, Hashable {
    public var ipv4MedianMs: Double?
    public var ipv6MedianMs: Double?
    public var ipv4LossPercent: Double?
    public var ipv6LossPercent: Double?
    public var verdict: IPFamilyVerdict
}

public struct NetworkGroupSummary: Codable, Sendable, Hashable, Identifiable {
    public var networkClass: NetworkClass
    public var testIDs: [UUID]
    public var degraded: Bool
    public var reasons: [String]
    public var id: NetworkClass { networkClass }
}

public enum InterfaceVerdict: String, Codable, Sendable, Hashable {
    case insufficientData, allNormal, wifiNormalCellularDegraded, cellularNormalWifiDegraded, allCellularDegradedWifiNormal, allDegraded, mixed
}

public enum RadioVerdict: String, Codable, Sendable, Hashable {
    case insufficientData, bothNormal, lteNormalNRDegraded, nrNormalLTEDegraded, bothDegraded
}

public struct InterfaceComparison: Codable, Sendable, Hashable {
    public var groups: [NetworkGroupSummary]
    public var verdict: InterfaceVerdict
    public var radioVerdict: RadioVerdict
}

public struct CrossTestReport: Codable, Sendable, Hashable {
    public var servers: ServerComparison
    public var ipFamilies: IPFamilyComparison
    public var interfaces: InterfaceComparison
}

// MARK: - Analyzer

/// Compares the tests of a session with each other.
///
/// **Servers** — every server used by a session test and every cross-validation endpoint is
/// one entry. An entry is anomalous when (best = lowest median among entries):
///
///     loss > 2 %   OR   median > max(2 × best, best + 50 ms)   OR   probe failed
///
///     verdict: < 2 entries → insufficient; 0 anomalous → allNormal; all → allServersAnomalous;
///              1 → singleServerAnomalous; otherwise multipleServersAnomalous
///
/// **Throughput outlier** — with ≥ 2 speed-tested servers, a server whose download is < 50 % of
/// the best one is an outlier (server capacity limit rather than the user's line).
///
/// **IP families** — IPv6 is degraded relative to IPv4 when
///
///     loss₆ − loss₄ > 2 pp   OR   median₆ > 1.5 × median₄ + 20 ms       (and symmetrically)
///
/// **Interfaces** — tests are grouped by `NetworkClass`; a group is degraded when more than half
/// of its tests fail `TestHealthEvaluator`. Wi-Fi/wired vs cellular and LTE vs 5G verdicts are
/// derived from the group states.
public struct CrossTestAnalyzer: Sendable {
    public var thresholds: HealthThresholds

    public init(thresholds: HealthThresholds = .standard) {
        self.thresholds = thresholds
    }

    public func analyze(_ session: DiagnosticSession) -> CrossTestReport {
        CrossTestReport(servers: compareServers(session), ipFamilies: compareIPFamilies(session), interfaces: compareInterfaces(session))
    }

    // MARK: Servers

    struct RawEntry {
        var id: String, name: String, region: String, method: String
        var stats: [LatencyStatistics] = []
        var downloads: [Double] = []
        var errors: [String] = []
        var unhealthy = false
    }

    public func compareServers(_ session: DiagnosticSession) -> ServerComparison {
        var raw: [String: RawEntry] = [:]
        var order: [String] = []
        func entry(_ id: String, _ name: String, _ region: String, _ method: String, _ update: (inout RawEntry) -> Void) {
            if raw[id] == nil { raw[id] = RawEntry(id: id, name: name, region: region, method: method); order.append(id) }
            update(&raw[id]!)
        }

        for test in session.tests {
            let r = test.result
            if let server = r.server {
                entry(server.id, server.name, server.location, "speed test") { e in
                    if let lat = r.idleLatency { e.stats.append(lat) }
                    if let dl = r.download?.summary.averageMbps { e.downloads.append(dl) }
                    if r.serverHealth?.healthy == false { e.unhealthy = true }
                }
            }
            for check in r.crossValidation ?? [] where !(check.isPrimary && r.server?.id == check.id) {
                entry(check.id, check.name, check.region, check.method.rawValue) { e in
                    if let s = check.statistics { e.stats.append(s) }
                    if let err = check.error { e.errors.append(err) }
                }
            }
        }

        // Per-entry medians / loss (pooled across tests by averaging).
        struct Summary { var median: Double?; var loss: Double?; var dl: Double?; var failed: Bool }
        var summaries: [String: Summary] = [:]
        for id in order {
            let e = raw[id]!
            let medians = e.stats.compactMap { $0.rtt?.median }
            let losses = e.stats.filter { $0.sent > 0 }.map(\.loss.lossPercent)
            let failed = medians.isEmpty && (!e.errors.isEmpty || e.stats.contains { $0.sent > 0 && $0.rtt == nil })
            summaries[id] = Summary(median: Descriptive.mean(medians), loss: Descriptive.mean(losses),
                                    dl: e.downloads.max(), failed: failed)
        }

        let measuredIDs = order.filter { summaries[$0]!.median != nil || summaries[$0]!.failed }
        let best = measuredIDs.compactMap { summaries[$0]!.median }.min()

        var entries: [ServerComparisonEntry] = []
        for id in order {
            let e = raw[id]!, s = summaries[id]!
            var reasons: [String] = []
            if s.failed { reasons.append("無回應或連線失敗") }
            if let loss = s.loss, loss > thresholds.maxLossPercent { reasons.append("遺失 \(Fmt.d(loss, 1))%") }
            if let median = s.median, let best, median > max(2 * best, best + 50) {
                reasons.append("延遲 \(Fmt.d(median, 0)) ms（最佳 \(Fmt.d(best, 0)) ms）")
            }
            if e.unhealthy { reasons.append("伺服器健康檢查異常") }
            entries.append(ServerComparisonEntry(id: id, name: e.name, region: e.region, method: e.method,
                                                 latencyMedianMs: s.median, lossPercent: s.loss, downloadMbps: s.dl,
                                                 isAnomalous: !reasons.isEmpty, reasons: reasons))
        }

        let measured = entries.filter { measuredIDs.contains($0.id) }
        let anomalous = measured.filter(\.isAnomalous)
        let verdict: ServerComparisonVerdict
        if measured.count < 2 { verdict = .insufficientData }
        else if anomalous.isEmpty { verdict = .allNormal }
        else if anomalous.count == measured.count { verdict = .allServersAnomalous }
        else if anomalous.count == 1 { verdict = .singleServerAnomalous }
        else { verdict = .multipleServersAnomalous }

        var anomalousRegion: String?
        let anomalousRegions = Set(anomalous.map(\.region))
        if anomalous.count >= 2, anomalousRegions.count == 1, let region = anomalousRegions.first,
           measured.contains(where: { !$0.isAnomalous && $0.region != region }) {
            anomalousRegion = region
        }

        let speedTested = entries.filter { $0.downloadMbps != nil }
        var outliers: [String] = []
        var consistent: Bool?
        if speedTested.count >= 2, let top = speedTested.compactMap(\.downloadMbps).max(), top > 0 {
            outliers = speedTested.filter { $0.downloadMbps! < 0.5 * top }.map(\.id)
            consistent = outliers.isEmpty
        }
        return ServerComparison(entries: entries, verdict: verdict, anomalousRegion: anomalousRegion,
                                throughputOutlierIDs: outliers, throughputConsistent: consistent)
    }

    // MARK: IP families

    public func compareIPFamilies(_ session: DiagnosticSession) -> IPFamilyComparison {
        var v4: [LatencyStatistics] = [], v6: [LatencyStatistics] = []
        var v4Failed = false, v6Failed = false
        for test in session.tests {
            let r = test.result
            if let c = r.ipFamilyComparison {
                if let s = c.ipv4 { v4.append(s) } else if c.ipv4Error != nil { v4Failed = true }
                if let s = c.ipv6 { v6.append(s) } else if c.ipv6Error != nil { v6Failed = true }
            }
            switch r.ipFamilyPreference {
            case .ipv4Only: if let s = r.idleLatency { v4.append(s) }
            case .ipv6Only: if let s = r.idleLatency { v6.append(s) }
            case .automatic: break
            }
        }
        func median(_ s: [LatencyStatistics]) -> Double? { Descriptive.mean(s.compactMap { $0.rtt?.median }) }
        func loss(_ s: [LatencyStatistics]) -> Double? { Descriptive.mean(s.filter { $0.sent > 0 }.map(\.loss.lossPercent)) }
        let m4 = median(v4), m6 = median(v6), l4 = loss(v4), l6 = loss(v6)

        let verdict: IPFamilyVerdict
        if m4 != nil, m6 == nil, v6Failed {
            verdict = .ipv6Unavailable
        } else if let m4, let m6 {
            let lossDiff = (l6 ?? 0) - (l4 ?? 0)
            let v6Worse = lossDiff > 2 || m6 > 1.5 * m4 + 20
            let v4Worse = -lossDiff > 2 || m4 > 1.5 * m6 + 20
            let bothBad = (l4 ?? 0) > thresholds.maxLossPercent && (l6 ?? 0) > thresholds.maxLossPercent
            if bothBad { verdict = .bothDegraded }
            else if v6Worse { verdict = .ipv6Degraded }
            else if v4Worse { verdict = .ipv4Degraded }
            else { verdict = .equivalent }
        } else {
            verdict = .insufficientData
        }
        return IPFamilyComparison(ipv4MedianMs: m4, ipv6MedianMs: m6, ipv4LossPercent: l4, ipv6LossPercent: l6, verdict: verdict)
    }

    // MARK: Interfaces

    public func compareInterfaces(_ session: DiagnosticSession) -> InterfaceComparison {
        var states: [NetworkClass: (ids: [UUID], degraded: Int, total: Int, reasons: [String])] = [:]
        func add(_ cls: NetworkClass, _ id: UUID, _ a: TestHealthAssessment) {
            guard a.measured, cls != .unknown else { return }
            var s = states[cls] ?? ([], 0, 0, [])
            if !s.ids.contains(id) { s.ids.append(id) }
            s.total += 1
            if a.isDegraded { s.degraded += 1; s.reasons.append(contentsOf: a.reasons) }
            states[cls] = s
        }
        for test in session.tests {
            add(test.networkClass, test.id, TestHealthEvaluator.assess(test.result, thresholds: thresholds))
            // Per-interface latency probes taken inside a single test (e.g. cellular probed while on Wi-Fi).
            for probe in test.result.interfaceCompare ?? [] where probe.interface != test.result.network.primaryInterface {
                let cls: NetworkClass = switch probe.interface {
                case .wifi: .wifi
                case .wiredEthernet: .wired
                case .cellular: .cellularOther
                default: .unknown
                }
                add(cls, test.id, TestHealthEvaluator.assess(probe.tcpConnect, error: probe.error, thresholds: thresholds))
            }
        }
        let groups = NetworkClass.allCases.compactMap { cls -> NetworkGroupSummary? in
            guard let s = states[cls] else { return nil }
            return NetworkGroupSummary(networkClass: cls, testIDs: s.ids, degraded: Double(s.degraded) > Double(s.total) / 2,
                                       reasons: Array(Set(s.reasons)).sorted())
        }

        let fixed = groups.filter { $0.networkClass.isFixed }
        let cellular = groups.filter { $0.networkClass.isCellular }
        let verdict: InterfaceVerdict
        if groups.count < 2 {
            verdict = .insufficientData
        } else if groups.allSatisfy({ !$0.degraded }) {
            verdict = .allNormal
        } else if groups.allSatisfy(\.degraded) {
            verdict = .allDegraded
        } else if !fixed.isEmpty, !cellular.isEmpty, fixed.allSatisfy({ !$0.degraded }), cellular.allSatisfy(\.degraded) {
            let rats = Set(cellular.map(\.networkClass)).intersection([.lte, .nr])
            verdict = rats.count >= 2 ? .allCellularDegradedWifiNormal : .wifiNormalCellularDegraded
        } else if !fixed.isEmpty, !cellular.isEmpty, fixed.allSatisfy(\.degraded), cellular.allSatisfy({ !$0.degraded }) {
            verdict = .cellularNormalWifiDegraded
        } else {
            verdict = .mixed
        }

        let radioVerdict: RadioVerdict
        if let lte = groups.first(where: { $0.networkClass == .lte }), let nr = groups.first(where: { $0.networkClass == .nr }) {
            switch (lte.degraded, nr.degraded) {
            case (false, false): radioVerdict = .bothNormal
            case (false, true): radioVerdict = .lteNormalNRDegraded
            case (true, false): radioVerdict = .nrNormalLTEDegraded
            case (true, true): radioVerdict = .bothDegraded
            }
        } else {
            radioVerdict = .insufficientData
        }
        return InterfaceComparison(groups: groups, verdict: verdict, radioVerdict: radioVerdict)
    }
}
