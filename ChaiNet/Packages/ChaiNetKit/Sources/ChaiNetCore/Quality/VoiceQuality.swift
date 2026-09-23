import Foundation

/// Voice call quality rating (ITU-T G.107 user-satisfaction bands).
public enum VoiceRating: String, Codable, Sendable, Hashable {
    case excellent, good, fair, poor, bad

    /// R-factor bands: ≥ 90 very satisfied, ≥ 80 satisfied, ≥ 70 some dissatisfied,
    /// ≥ 60 many dissatisfied, < 60 nearly all dissatisfied.
    public static func from(rFactor r: Double) -> VoiceRating {
        switch r {
        case 90...: .excellent
        case 80..<90: .good
        case 70..<80: .fair
        case 60..<70: .poor
        default: .bad
        }
    }
}

public struct VoiceQualityResult: Codable, Sendable, Hashable {
    public var latency: LatencyStatistics
    public var effectiveLatencyMs: Double
    public var rFactor: Double
    public var mos: Double
    public var rating: VoiceRating
    public var packetsPerSecond: Double
    public var payloadBytes: Int
}

/// Simplified ITU-T G.107 E-model, as widely used by VoIP monitoring tools.
///
///     EL = avgLatency + 2 × jitter + 10                     (effective latency, ms;
///                                                            +10 ms codec/processing allowance)
///     R  = 93.2 − EL / 40                  if EL < 160
///     R  = 93.2 − (EL − 120) / 10          otherwise
///     R  = R − 2.5 × loss%
///     R  = clamp(R, 0, 100)
///     MOS = 1                                               if R ≤ 0
///     MOS = 1 + 0.035 R + 7·10⁻⁶ · R (R − 60)(100 − R)      if 0 < R < 100
///     MOS = 4.5                                             if R ≥ 100
///
/// `avgLatency` is the measured round-trip time. Using RTT instead of one-way delay is the
/// conventional (conservative) choice for tools that cannot measure one-way delay.
public enum VoiceQualityCalculator {
    public static func effectiveLatency(averageMs: Double, jitterMs: Double) -> Double {
        averageMs + 2 * jitterMs + 10
    }

    public static func rFactor(averageLatencyMs: Double, jitterMs: Double, lossPercent: Double) -> Double {
        let el = effectiveLatency(averageMs: averageLatencyMs, jitterMs: jitterMs)
        var r = el < 160 ? 93.2 - el / 40 : 93.2 - (el - 120) / 10
        r -= 2.5 * lossPercent
        return Descriptive.clamp(r, 0...100)
    }

    public static func mos(rFactor r: Double) -> Double {
        if r <= 0 { return 1 }
        if r >= 100 { return 4.5 }
        return 1 + 0.035 * r + 0.000007 * r * (r - 60) * (100 - r)
    }

    public static func evaluate(_ stats: LatencyStatistics, packetsPerSecond: Double, payloadBytes: Int) -> VoiceQualityResult {
        let avg = stats.rtt?.average ?? 1000
        let jitter = stats.rtt?.jitter ?? 0
        let r = rFactor(averageLatencyMs: avg, jitterMs: jitter, lossPercent: stats.loss.lossPercent)
        return VoiceQualityResult(
            latency: stats,
            effectiveLatencyMs: effectiveLatency(averageMs: avg, jitterMs: jitter),
            rFactor: r,
            mos: mos(rFactor: r),
            rating: .from(rFactor: r),
            packetsPerSecond: packetsPerSecond,
            payloadBytes: payloadBytes)
    }
}
