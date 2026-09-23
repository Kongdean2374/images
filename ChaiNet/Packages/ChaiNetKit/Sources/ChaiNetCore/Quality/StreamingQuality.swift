import Foundation

public struct StreamingTier: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// Typical adaptive-bitrate requirement (Mbps).
    public var requiredMbps: Double
    public var id: String { name }

    public static let standard: [StreamingTier] = [
        StreamingTier(name: "480p SD", requiredMbps: 3),
        StreamingTier(name: "720p HD", requiredMbps: 5),
        StreamingTier(name: "1080p Full HD", requiredMbps: 8),
        StreamingTier(name: "1440p QHD", requiredMbps: 16),
        StreamingTier(name: "4K UHD", requiredMbps: 25),
        StreamingTier(name: "4K HDR（高位元率）", requiredMbps: 40),
    ]
}

public struct StreamingTierVerdict: Codable, Sendable, Hashable, Identifiable {
    public var tier: StreamingTier
    public var supported: Bool
    /// sustained / required
    public var headroom: Double
    public var id: String { tier.id }
}

public struct StreamingQualityResult: Codable, Sendable, Hashable {
    public var download: SpeedResult
    public var ttfbMs: Double?
    /// P10 of throughput — the rate available 90 % of the time.
    public var sustainedMbps: Double
    public var tiers: [StreamingTierVerdict]
    public var maxSupportedTier: StreamingTier?
    /// Estimated time to fill a 2 s buffer at the max supported tier, plus TTFB.
    public var estimatedStartupMs: Double?
    public var score: Int?
}

/// Streaming suitability.
///
///     sustained     = P10(download interval throughput)
///     supported     ⇔ sustained ≥ 1.25 × required         (25 % ABR headroom)
///     startup (ms)  = TTFB + (bufferSeconds × tierMbps / sustained) × 1000
///
/// P10 rather than the average is used because adaptive-bitrate players drop quality when
/// throughput dips, so the dips — not the average — decide the resolution you actually get.
public enum StreamingQualityCalculator {
    public static let headroomFactor = 1.25

    public static func evaluate(download: SpeedResult, ttfbMs: Double?, bufferSeconds: Double = 2,
                                tiers: [StreamingTier] = StreamingTier.standard, score: Int?) -> StreamingQualityResult {
        let sustained = download.summary.p10Mbps
        let verdicts = tiers.map { tier in
            StreamingTierVerdict(tier: tier, supported: sustained >= tier.requiredMbps * headroomFactor,
                                 headroom: tier.requiredMbps > 0 ? sustained / tier.requiredMbps : 0)
        }
        let best = verdicts.last(where: \.supported)?.tier
        var startup: Double?
        if let best, sustained > 0 {
            startup = (ttfbMs ?? 0) + bufferSeconds * best.requiredMbps / sustained * 1000
        }
        return StreamingQualityResult(download: download, ttfbMs: ttfbMs, sustainedMbps: sustained, tiers: verdicts,
                                      maxSupportedTier: best, estimatedStartupMs: startup, score: score)
    }
}
