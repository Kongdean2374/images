import Foundation

/// A cumulative received-bytes counter reported by the *server* (e.g. NDT7 `AppInfo.NumBytes`).
public struct ServerByteSample: Codable, Sendable, Hashable {
    /// Seconds since the transfer started (server clock).
    public var offset: Double
    public var bytes: Int64
    public init(offset: Double, bytes: Int64) {
        self.offset = offset
        self.bytes = bytes
    }
}

/// Upload throughput from receiver-side counters — immune to client write-completion batching.
///
///     average = (bytes_last − bytes_first_steady) × 8 / (t_last − t_first_steady)     steady = t ≥ 1 s
///     windows = consecutive non-overlapping ≥ 1 s intervals of the cumulative counter
public struct ServerConfirmedThroughput: Codable, Sendable, Hashable {
    public var source: String
    public var samples: [ServerByteSample]
    public var averageMbps: Double
    public var windowMbps: [Double]
    public var medianMbps: Double?
    public var p10Mbps: Double?
    public var stabilityScore: Double?

    public static func make(source: String, samples raw: [ServerByteSample], warmup: Double = 1.0) -> ServerConfirmedThroughput? {
        let samples = raw.sorted { $0.offset < $1.offset }
        let steady = samples.filter { $0.offset >= warmup }
        guard let first = steady.first, let last = steady.last, last.offset > first.offset else { return nil }
        let average = SpeedMath.mbps(bytes: last.bytes - first.bytes, seconds: last.offset - first.offset)
        var windows: [Double] = []
        var start = first
        for s in steady where s.offset - start.offset >= 1.0 {
            windows.append(SpeedMath.mbps(bytes: s.bytes - start.bytes, seconds: s.offset - start.offset))
            start = s
        }
        return ServerConfirmedThroughput(source: source, samples: samples, averageMbps: average, windowMbps: windows,
                                         medianMbps: Descriptive.median(windows), p10Mbps: Percentile.value(0.10, in: windows),
                                         stabilityScore: windows.count >= 3 ? StabilityCalculator.evaluate(windows).score : nil)
    }
}
