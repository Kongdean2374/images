import Foundation

/// Stability of a throughput (or any positive) series.
public struct StabilityMetrics: Codable, Sendable, Hashable {
    /// σ / μ of the series. `nil` when undefined (empty series or zero mean).
    public var coefficientOfVariation: Double?
    /// 0–100, higher is steadier. `nil` when undefined.
    public var score: Double?
    /// Number of samples below `dropThresholdFraction × median`.
    public var dropCount: Int
    /// Fraction of the median used to detect drops (default 0.5).
    public var dropThresholdFraction: Double

    public static let undefined = StabilityMetrics(coefficientOfVariation: nil, score: nil, dropCount: 0, dropThresholdFraction: 0.5)
}

/// Speed-stability calculation.
///
///     CV    = σ / μ                              (population σ)
///     score = clamp( (1 − CV) × 100 , 0 , 100 )
///     drops = #{ xᵢ < dropFraction × median(x) }
///
/// Interpretation: CV 0.05 → 95 (very steady), CV 0.30 → 70, CV ≥ 1 → 0 (chaotic).
/// The drop count complements CV because a few deep dips (e.g. Wi-Fi retransmission stalls)
/// hurt real-time use more than the CV alone suggests.
public enum StabilityCalculator {
    public static func evaluate(_ series: [Double], dropThresholdFraction: Double = 0.5) -> StabilityMetrics {
        guard let cv = Descriptive.coefficientOfVariation(series), let median = Descriptive.median(series) else {
            return StabilityMetrics(coefficientOfVariation: nil, score: nil, dropCount: 0, dropThresholdFraction: dropThresholdFraction)
        }
        let score = Descriptive.clamp((1 - cv) * 100, 0...100)
        let drops = series.filter { $0 < dropThresholdFraction * median }.count
        return StabilityMetrics(coefficientOfVariation: cv, score: score, dropCount: drops, dropThresholdFraction: dropThresholdFraction)
    }
}
