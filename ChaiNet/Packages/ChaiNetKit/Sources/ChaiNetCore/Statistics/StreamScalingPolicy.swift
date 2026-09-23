import Foundation

/// Adaptive parallel-stream policy for the speed test.
///
/// A single TCP connection is limited by its congestion window (≈ cwnd / RTT), so fast links
/// need several connections to be saturated, while slow links get *less* accurate with many
/// connections (they fight each other and add overhead). The engine starts with the minimum
/// count and re-evaluates periodically during the ramp-up phase.
///
/// Tiers (measured aggregate throughput → streams):
///
///     < 25 Mbps    → 2
///     < 100 Mbps   → 4
///     < 400 Mbps   → 8
///     ≥ 400 Mbps   → 16
///
/// The count only ever increases within a run (`nextStreamCount`) — tearing down connections
/// mid-test would create an artificial throughput dip.
public struct StreamScalingPolicy: Sendable, Hashable, Codable {
    public struct Tier: Sendable, Hashable, Codable {
        /// Upper bound (exclusive) of throughput for this tier. `nil` = unbounded.
        public var belowMbps: Double?
        public var streams: Int
        public init(belowMbps: Double?, streams: Int) {
            self.belowMbps = belowMbps
            self.streams = streams
        }
    }

    public var tiers: [Tier]

    public static let allowedStreamCounts = [2, 4, 8, 16]

    public static let `default` = StreamScalingPolicy(tiers: [
        Tier(belowMbps: 25, streams: 2),
        Tier(belowMbps: 100, streams: 4),
        Tier(belowMbps: 400, streams: 8),
        Tier(belowMbps: nil, streams: 16),
    ])

    public init(tiers: [Tier]) {
        self.tiers = tiers
    }

    public var initialStreams: Int { tiers.first?.streams ?? 2 }
    public var maximumStreams: Int { tiers.map(\.streams).max() ?? 16 }

    /// Stream count recommended for a measured throughput.
    public func recommendedStreams(forMbps mbps: Double) -> Int {
        for tier in tiers {
            guard let bound = tier.belowMbps else { return tier.streams }
            if mbps < bound { return tier.streams }
        }
        return maximumStreams
    }

    /// Next stream count given the current one; never decreases.
    public func nextStreamCount(current: Int, measuredMbps: Double) -> Int {
        max(current, recommendedStreams(forMbps: measuredMbps))
    }
}
