import Foundation

/// One DNS lookup, as exported (the sample sequence number is the index into `domains`).
public struct DNSLookupRow: Codable, Sendable, Hashable {
    public var domain: String
    public var transport: DNSTransport
    public var resolverID: String
    public var latencyMs: Double?
    /// "ok" or "fail".
    public var status: String
    /// The OS / resolver cache state is not observable from the app: always "unknown".
    public var cached: String
}

public enum DNSFindingKind: String, Codable, Sendable, Hashable {
    /// A resolver is slow or failing across domains.
    case resolverWideDegradation
    /// One domain is slow on several resolvers (cold authoritative lookup) — not a resolver problem.
    case domainSpecificOutlier
    /// Every resolver of one transport (UDP / DoH) degraded while another transport was fine.
    case transportSpecificIssue
    /// An IPv6 resolver endpoint fails / is slow while the same operator's IPv4 endpoint is healthy.
    case ipv6DNSPathIssue
}

public struct DNSFinding: Codable, Sendable, Hashable {
    public var kind: DNSFindingKind
    /// Resolver id, domain or transport.
    public var subject: String
    public var detail: String
}

/// Classifies DNS benchmark results so one cold lookup is not mistaken for a bad resolver:
///
///     resolver-wide     : failures ≥ 20 % of attempted lookups, or median > 100 ms (≥ 3 answers)
///     domain outlier    : the same domain > max(3 × resolver median, resolver median + 100 ms)
///                         on ≥ 2 resolvers
///     transport-specific: every resolver of a transport resolver-wide degraded, another transport not
///     IPv6 DNS path     : IPv6-endpoint resolver with failures or resolver-wide degradation while the
///                         same operator's IPv4 resolver is healthy
public enum DNSAnalyzer {
    public static func rows(_ result: DNSBenchmarkResult) -> [DNSLookupRow] {
        result.resolvers.flatMap { r in
            r.samples.map { s in
                DNSLookupRow(domain: result.domains.indices.contains(s.sequence) ? result.domains[s.sequence] : "#\(s.sequence)",
                             transport: r.resolver.transport, resolverID: r.resolver.id, latencyMs: s.rttMs,
                             status: s.rttMs == nil ? "fail" : "ok", cached: "unknown")
            }
        }
    }

    static func isIPv6(_ r: DNSResolverDescriptor) -> Bool { r.endpoint.contains(":") && !r.endpoint.contains("/") }
    static func operatorKey(_ r: DNSResolverDescriptor) -> String { String(r.id.split(separator: "-").first ?? Substring(r.id)) }

    static func resolverWide(_ r: DNSResolverResult) -> Bool {
        let attempted = r.samples.count
        let failed = r.samples.filter { $0.rttMs == nil }.count
        let answered = r.samples.compactMap(\.rttMs)
        if attempted > 0 && Double(failed) / Double(attempted) >= 0.2 { return true }
        if answered.count >= 3, let m = Descriptive.median(answered), m > 100 { return true }
        return false
    }

    /// Domains slow on ≥ 2 resolvers relative to each resolver's own median.
    public static func outlierDomains(_ result: DNSBenchmarkResult) -> [String] {
        var hits: [Int: Int] = [:]
        for r in result.resolvers {
            guard let median = Descriptive.median(r.samples.compactMap(\.rttMs)) else { continue }
            let limit = max(3 * median, median + 100)
            for s in r.samples { if let v = s.rttMs, v > limit { hits[s.sequence, default: 0] += 1 } }
        }
        return hits.filter { $0.value >= 2 }.keys.sorted().compactMap { result.domains.indices.contains($0) ? result.domains[$0] : nil }
    }

    public static func analyze(_ result: DNSBenchmarkResult) -> [DNSFinding] {
        var out: [DNSFinding] = []
        let wide = Set(result.resolvers.filter(resolverWide).map(\.resolver.id))
        for r in result.resolvers where wide.contains(r.resolver.id) {
            let failed = r.samples.filter { $0.rttMs == nil }.count
            out.append(DNSFinding(kind: .resolverWideDegradation, subject: r.resolver.id,
                                  detail: "\(r.resolver.name)：失敗 \(failed)/\(r.samples.count)，中位數 \(r.statistics.rtt.map { Fmt.d($0.median, 0) } ?? "—") ms"))
        }
        for d in outlierDomains(result) {
            out.append(DNSFinding(kind: .domainSpecificOutlier, subject: d, detail: "\(d) 在多個解析器都特別慢（冷查詢 / 權威伺服器），非解析器問題"))
        }
        let byTransport = Dictionary(grouping: result.resolvers.filter { $0.resolver.transport != .system }, by: \.resolver.transport)
        for (transport, rs) in byTransport where !rs.isEmpty && rs.allSatisfy({ wide.contains($0.resolver.id) }) {
            let others = byTransport.filter { $0.key != transport }.values.flatMap { $0 }
            if others.contains(where: { !wide.contains($0.resolver.id) }) {
                out.append(DNSFinding(kind: .transportSpecificIssue, subject: transport.rawValue, detail: "所有 \(transport.rawValue) 解析器皆異常，其他傳輸方式正常"))
            }
        }
        for r in result.resolvers where isIPv6(r.resolver) {
            let failed = r.samples.filter { $0.rttMs == nil }.count
            guard failed > 0 || wide.contains(r.resolver.id) else { continue }
            let key = operatorKey(r.resolver)
            let v4Healthy = result.resolvers.contains { !isIPv6($0.resolver) && $0.resolver.transport == r.resolver.transport
                && operatorKey($0.resolver) == key && !wide.contains($0.resolver.id) && !$0.samples.contains { $0.rttMs == nil } }
            if v4Healthy {
                out.append(DNSFinding(kind: .ipv6DNSPathIssue, subject: r.resolver.id,
                                      detail: "\(r.resolver.name) 失敗 \(failed)/\(r.samples.count)，同業者 IPv4 解析器正常：IPv6 DNS 路徑特定問題"))
            }
        }
        return out
    }

    /// System resolver statistics with outlier domains removed (to tell a domain-specific cold
    /// lookup apart from resolver tail latency).
    public static func systemStatsExcludingOutliers(_ result: DNSBenchmarkResult) -> LatencyStatistics? {
        guard let system = result.resolvers.first(where: { $0.resolver.transport == .system }) else { return nil }
        let outliers = Set(outlierDomains(result))
        let kept = system.samples.filter { s in !(result.domains.indices.contains(s.sequence) && outliers.contains(result.domains[s.sequence])) }
        return LatencyStatistics.compute(from: kept)
    }
}
