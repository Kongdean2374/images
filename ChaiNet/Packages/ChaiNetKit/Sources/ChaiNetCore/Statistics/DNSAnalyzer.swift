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
    /// One domain slow on the system resolver only, the same domain fast on other resolvers.
    case domainSpecificSystemResolverOutlier
    /// One domain slow on one (non-system) resolver only.
    case domainSpecificResolverOutlier
    /// Every resolver of one transport (UDP / DoH) degraded while another transport was fine.
    case transportSpecificIssue
    /// An IPv6 resolver endpoint fails / is slow while the same operator's IPv4 endpoint is healthy.
    case ipv6DNSPathIssue
}

/// One robust-statistics outlier lookup with its cross-resolver validation.
public struct DNSOutlier: Codable, Sendable, Hashable {
    public var domain: String
    public var resolverID: String
    public var latencyMs: Double
    public var kind: DNSFindingKind
    /// Human / AI readable rule that fired, with the numbers.
    public var reason: String
    /// Same domain on the other resolvers: resolver id → latency (nil = failed).
    public var comparisonResolvers: [String: Double?]
    public var confidenceBand: ConfidenceBand
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

    /// Robust per-resolver outlier rule (median / MAD — one huge value can't hide itself by
    /// inflating the mean or P95):
    ///
    ///     MAD      = median(|x − median|);  σ̂ = 1.4826 × MAD
    ///     outlier ⇔ x − median ≥ max(3.5 σ̂, 50 ms)  and  x ≥ 2 × median
    public static let madZ = 3.5
    public static let minimumExcessMs = 50.0

    static func robustOutlierLimit(_ values: [Double]) -> (median: Double, limit: Double, sigma: Double)? {
        guard values.count >= 4, let median = Descriptive.median(values),
              let mad = Descriptive.median(values.map { abs($0 - median) }) else { return nil }
        let sigma = 1.4826 * mad
        return (median, max(median + max(madZ * sigma, minimumExcessMs), 2 * median), sigma)
    }

    /// Outlier lookups with cross-resolver validation (same domain on the other resolvers):
    ///
    ///     outlier on ≥ 2 resolvers                         → domainSpecificOutlier (cold authoritative)
    ///     outlier on the system resolver only, others fast → domainSpecificSystemResolverOutlier
    ///     outlier on one other resolver only              → domainSpecificResolverOutlier
    ///     confidence_band: high ≥ 2 fast comparison resolvers · medium 1 · low none
    public static func outliers(_ result: DNSBenchmarkResult) -> [DNSOutlier] {
        var limits: [String: (median: Double, limit: Double, sigma: Double)] = [:]
        for r in result.resolvers { limits[r.resolver.id] = robustOutlierLimit(r.samples.compactMap(\.rttMs)) }
        func isOutlier(_ r: DNSResolverResult, _ v: Double) -> Bool { limits[r.resolver.id].map { v >= $0.limit } ?? false }
        // Hits per domain index.
        var hits: [Int: [(DNSResolverResult, Double)]] = [:]
        for r in result.resolvers {
            for s in r.samples { if let v = s.rttMs, isOutlier(r, v) { hits[s.sequence, default: []].append((r, v)) } }
        }
        var out: [DNSOutlier] = []
        for seq in hits.keys.sorted() {
            guard result.domains.indices.contains(seq), let group = hits[seq] else { continue }
            let domain = result.domains[seq]
            let slowIDs = Set(group.map { $0.0.resolver.id })
            for (r, v) in group {
                var comparison: [String: Double?] = [:]
                for other in result.resolvers where other.resolver.id != r.resolver.id {
                    if let sample = other.samples.first(where: { $0.sequence == seq }) { comparison[other.resolver.id] = sample.rttMs }
                }
                let fast = comparison.filter { entry in !slowIDs.contains(entry.key) && entry.value != nil }.count
                let kind: DNSFindingKind = slowIDs.count >= 2 ? .domainSpecificOutlier
                    : (r.resolver.transport == .system ? .domainSpecificSystemResolverOutlier : .domainSpecificResolverOutlier)
                let band: ConfidenceBand = slowIDs.count >= 2 ? (slowIDs.count >= 3 ? .high : .medium) : (fast >= 2 ? .high : (fast == 1 ? .medium : .low))
                let l = limits[r.resolver.id]!
                out.append(DNSOutlier(domain: domain, resolverID: r.resolver.id, latencyMs: v, kind: kind,
                                      reason: "latency \(Fmt.d(v, 2)) ms ≥ limit \(Fmt.d(l.limit, 2)) ms (resolver median \(Fmt.d(l.median, 2)) ms, 1.4826×MAD \(Fmt.d(l.sigma, 2)) ms, rule max(median+max(3.5σ,50), 2×median)); slow on \(slowIDs.count) resolver(s)",
                                      comparisonResolvers: comparison, confidenceBand: band))
            }
        }
        return out
    }

    /// Domains with at least one outlier lookup (any kind), in benchmark order.
    public static func outlierDomains(_ result: DNSBenchmarkResult) -> [String] {
        var seen = Set<String>()
        return outliers(result).map(\.domain).filter { seen.insert($0).inserted }
    }

    public static func analyze(_ result: DNSBenchmarkResult) -> [DNSFinding] {
        var out: [DNSFinding] = []
        let wide = Set(result.resolvers.filter(resolverWide).map(\.resolver.id))
        for r in result.resolvers where wide.contains(r.resolver.id) {
            let failed = r.samples.filter { $0.rttMs == nil }.count
            out.append(DNSFinding(kind: .resolverWideDegradation, subject: r.resolver.id,
                                  detail: "\(r.resolver.name)：失敗 \(failed)/\(r.samples.count)，中位數 \(r.statistics.rtt.map { Fmt.d($0.median, 0) } ?? "—") ms"))
        }
        var reported = Set<String>()
        for o in outliers(result) where reported.insert("\(o.kind.rawValue)|\(o.domain)").inserted {
            let others = o.comparisonResolvers.keys.sorted().map { id -> String in
                let latency: Double? = o.comparisonResolvers[id] ?? nil
                return "\(id) " + (latency.map { Fmt.d($0, 0) + " ms" } ?? "失敗")
            }.joined(separator: "、")
            let detail: String
            switch o.kind {
            case .domainSpecificOutlier:
                detail = "\(o.domain) 在多個解析器都特別慢（冷查詢 / 權威伺服器），非解析器問題"
            case .domainSpecificSystemResolverOutlier:
                detail = "\(o.domain) 僅在系統解析器特別慢（\(Fmt.d(o.latencyMs, 0)) ms），其他解析器正常（\(others)）：單一網域 / 快取狀態，非系統 DNS 整體故障"
            default:
                detail = "\(o.domain) 僅在 \(o.resolverID) 特別慢（\(Fmt.d(o.latencyMs, 0)) ms），其他解析器：\(others)"
            }
            out.append(DNSFinding(kind: o.kind, subject: o.domain, detail: detail))
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
