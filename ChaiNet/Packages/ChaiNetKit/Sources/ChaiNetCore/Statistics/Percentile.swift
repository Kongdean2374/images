import Foundation

/// Percentile computation.
///
/// Method: linear interpolation between closest ranks — Hyndman & Fan "type 7", which is the
/// default of NumPy (`numpy.percentile`), R (`quantile(type = 7)`) and Excel `PERCENTILE.INC`.
///
/// For sorted values x₀ … xₙ₋₁ and a fraction p ∈ [0, 1]:
///
///     h = (n − 1) · p
///     P(p) = x⌊h⌋ + (h − ⌊h⌋) · (x⌊h⌋₊₁ − x⌊h⌋)
///
/// Examples: P(0) = minimum, P(1) = maximum, P(0.5) = median.
public enum Percentile {

    /// Percentile of an unsorted series. `p` is a fraction (0.95 = P95).
    public static func value(_ p: Double, in values: [Double]) -> Double? {
        value(p, sorted: values.sorted())
    }

    /// Percentile of an already ascending-sorted series (avoids re-sorting when computing
    /// several percentiles of the same data).
    public static func value(_ p: Double, sorted: [Double]) -> Double? {
        guard !sorted.isEmpty, p.isFinite else { return nil }
        let fraction = min(max(p, 0), 1)
        let h = Double(sorted.count - 1) * fraction
        let lower = Int(h.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = h - Double(lower)
        return sorted[lower] + weight * (sorted[upper] - sorted[lower])
    }
}
