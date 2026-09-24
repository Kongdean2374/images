import Foundation

/// DNS tail-latency rule shared by the diagnostics and root-cause engines.
///
///     highTailLatencyObserved ⇔ P95 ≥ 150 ms  AND  P95 ≥ 3 × median
///
/// A healthy median can hide occasional very slow lookups (cache misses, upstream retries);
/// those are what users feel as "the first page load hangs".
public enum DNSTail {
    public static let minimumP95Ms = 150.0
    public static let ratio = 3.0

    public static func isHigh(median: Double, p95: Double) -> Bool {
        p95 >= minimumP95Ms && p95 >= ratio * median
    }
}
