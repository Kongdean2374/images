import Foundation

/// Interprets traceroute hop latencies without over-reading them.
///
/// Routers answer ICMP Time-Exceeded on their slow path, so one hop showing 80 ms while the
/// next hops show 20 ms is the router deprioritising ICMP — *not* congestion. Only an increase
/// that persists into every later hop (including the destination) is a real path property.
///
///     floor[i]  = min(best RTT of responsive hops at TTL ≥ i)        (non-decreasing)
///     step      : floor[i] − floor[previous responsive hop] ≥ 30 ms, confirmed by at least one
///                 later responsive hop or by i being the destination
///     isolated  : median[i] − floor[i] ≥ 30 ms (later hops are faster) → ICMP reply
///                 deprioritisation / rate limiting, never "congestion"
public enum TracerouteAnalyzer {
    public static let thresholdMs = 30.0

    public struct Step: Codable, Sendable, Hashable {
        public var fromTTL: Int
        public var toTTL: Int
        public var increaseMs: Double
    }

    public struct IsolatedHop: Codable, Sendable, Hashable {
        public var ttl: Int
        public var excessMs: Double
    }

    public struct Analysis: Codable, Sendable, Hashable {
        public var steps: [Step]
        public var isolatedHighHops: [IsolatedHop]
        public var responsiveHopCount: Int
        /// Enough responsive hops (≥ 2) to say anything at all.
        public var sufficient: Bool { responsiveHopCount >= 2 }
        public var largestStep: Step? { steps.max { $0.increaseMs < $1.increaseMs } }
    }

    public static func analyze(_ hops: [TracerouteHop], thresholdMs: Double = thresholdMs) -> Analysis {
        let responsive = hops.sorted { $0.ttl < $1.ttl }.compactMap { h in h.bestMs.map { (hop: h, best: $0) } }
        guard !responsive.isEmpty else { return Analysis(steps: [], isolatedHighHops: [], responsiveHopCount: 0) }
        var floors = Array(repeating: 0.0, count: responsive.count)
        var running = Double.infinity
        for i in stride(from: responsive.count - 1, through: 0, by: -1) {
            running = min(running, responsive[i].best)
            floors[i] = running
        }
        var steps: [Step] = []
        var isolated: [IsolatedHop] = []
        for i in responsive.indices {
            // Isolated elevation uses the hop's median reply (one fast reply among slow ones — e.g.
            // 132 / 200 / 9.9 ms — is still ICMP slow-path handling, not path latency).
            let median = Descriptive.median(responsive[i].hop.rttsMs.compactMap { $0 }) ?? responsive[i].best
            let excess = median - floors[i]
            if excess >= thresholdMs { isolated.append(IsolatedHop(ttl: responsive[i].hop.ttl, excessMs: excess)) }
            guard i > 0 else { continue }
            let increase = floors[i] - floors[i - 1]
            let confirmed = i < responsive.count - 1 || responsive[i].hop.reachedDestination
            if increase >= thresholdMs && confirmed {
                steps.append(Step(fromTTL: responsive[i - 1].hop.ttl, toTTL: responsive[i].hop.ttl, increaseMs: increase))
            }
        }
        return Analysis(steps: steps, isolatedHighHops: isolated, responsiveHopCount: responsive.count)
    }
}
