import Foundation

/// Post-hoc latency spike analysis over a whole series (used for summaries and exports).
///
/// The streaming `LatencySpikeDetector` needs a learned baseline first, so a spike among the first
/// samples was invisible (a 324 ms outlier as the 2nd sample produced "spikes=0"). Here the
/// baseline is given (pre-load idle latency) or taken from the series itself:
///
///     threshold = max(baselineMedian + Δ, baselineP95 + Δ, baselineMedian × k)     Δ = 50 ms, k = 2
///     spike     ⇔ answered sample with RTT > threshold
public struct SpikeSummary: Codable, Sendable, Hashable {
    public var thresholdMs: Double
    public var count: Int
    public var worstMs: Double?
    public var offsets: [Double]
    public var baselineMedianMs: Double
    public var baselineP95Ms: Double
    /// "preLoadIdle" or "series".
    public var baselineSource: String
    public var deltaMs: Double
    public var multiplier: Double

    public var definition: String {
        "rtt > max(baseline_median + \(Fmt.d(deltaMs, 0)) ms, baseline_p95 + \(Fmt.d(deltaMs, 0)) ms, baseline_median x \(Fmt.d(multiplier, 1))); baseline=\(baselineSource)"
    }
}

public enum SpikeAnalyzer {
    public static let defaultDeltaMs = 50.0
    public static let defaultMultiplier = 2.0

    public static func analyze(_ samples: [LatencySample], baseline: LatencyStatistics? = nil,
                               deltaMs: Double = defaultDeltaMs, multiplier: Double = defaultMultiplier) -> SpikeSummary? {
        let answered = samples.compactMap { s in s.rttMs.map { (s.offset, $0) } }
        guard !answered.isEmpty else { return nil }
        let reference = baseline?.rtt ?? LatencyStatistics.compute(from: samples).rtt
        guard let ref = reference else { return nil }
        let threshold = max(ref.median + deltaMs, ref.p95 + deltaMs, ref.median * multiplier)
        let spikes = answered.filter { $0.1 > threshold }
        return SpikeSummary(thresholdMs: threshold, count: spikes.count, worstMs: spikes.map(\.1).max(), offsets: spikes.map(\.0),
                            baselineMedianMs: ref.median, baselineP95Ms: ref.p95,
                            baselineSource: baseline?.rtt != nil ? "preLoadIdle" : "series", deltaMs: deltaMs, multiplier: multiplier)
    }
}
