import Foundation

/// Basic descriptive statistics used by every engine.
///
/// All functions are pure and return `nil` for inputs where the statistic is undefined
/// (e.g. the mean of an empty series) instead of inventing a value.
public enum Descriptive {

    /// Arithmetic mean.
    ///
    ///     μ = (1 / n) · Σ xᵢ
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Median (50th percentile, linear interpolation — see `Percentile`).
    public static func median(_ values: [Double]) -> Double? {
        Percentile.value(0.5, in: values)
    }

    /// Population standard deviation.
    ///
    ///     σ = √( (1 / n) · Σ (xᵢ − μ)² )
    ///
    /// The population form is used because a measurement run is treated as the complete
    /// set of observations for that run (we are describing it, not estimating a wider
    /// population).
    public static func populationStandardDeviation(_ values: [Double]) -> Double? {
        guard let mu = mean(values) else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Sample standard deviation (Bessel-corrected).
    ///
    ///     s = √( (1 / (n − 1)) · Σ (xᵢ − μ)² )
    public static func sampleStandardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1, let mu = mean(values) else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    /// Coefficient of variation (relative dispersion).
    ///
    ///     CV = σ / μ
    ///
    /// Returns `nil` when the mean is zero (CV undefined).
    public static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard let mu = mean(values), mu != 0,
              let sigma = populationStandardDeviation(values) else { return nil }
        return sigma / abs(mu)
    }

    /// Median absolute deviation.
    ///
    ///     MAD = median( |xᵢ − median(x)| )
    ///
    /// Multiply by 1.4826 to obtain a robust estimate of σ for normally distributed data.
    public static func medianAbsoluteDeviation(_ values: [Double]) -> Double? {
        guard let m = median(values) else { return nil }
        return median(values.map { abs($0 - m) })
    }

    /// Simple moving average with a trailing window.
    ///
    ///     SMAᵢ = mean(x[i−w+1 ... i])   for i ≥ w − 1
    ///
    /// Returns an empty array when there are fewer than `window` values.
    public static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 0, values.count >= window else { return [] }
        var result: [Double] = []
        result.reserveCapacity(values.count - window + 1)
        var sum = values[0..<window].reduce(0, +)
        result.append(sum / Double(window))
        for i in window..<values.count {
            sum += values[i] - values[i - window]
            result.append(sum / Double(window))
        }
        return result
    }

    /// Clamps `value` to `range`.
    public static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
