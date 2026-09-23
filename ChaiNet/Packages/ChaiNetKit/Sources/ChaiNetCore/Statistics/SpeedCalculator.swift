import Foundation

/// Unit conversion for throughput.
public enum SpeedMath {
    /// Megabits per second from a byte count over a duration.
    ///
    ///     Mbps = bytes × 8 / seconds / 1 000 000
    ///
    /// Uses SI mega (10⁶) as is standard for network throughput. Returns 0 for non-positive
    /// durations rather than infinity.
    public static func mbps(bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }
}

/// Direction of a throughput test.
public enum TransferDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case download
    case upload
}

/// One point on the speed timeline.
///
/// The engine samples a shared byte counter at a fixed interval (default 100 ms). Each sample
/// describes the bytes transferred during that interval.
public struct SpeedSample: Codable, Sendable, Hashable, Identifiable {
    /// End of the interval, seconds since the transfer started.
    public var offset: Double
    /// Interval length in seconds.
    public var intervalDuration: Double
    /// Bytes moved during the interval (all streams combined).
    public var intervalBytes: Int64
    /// Bytes moved since the start of the test.
    public var cumulativeBytes: Int64
    /// Parallel connections active at the end of the interval.
    public var activeStreams: Int

    public var id: Double { offset }

    /// Instantaneous throughput for this interval (`SpeedMath.mbps`).
    public var mbps: Double { SpeedMath.mbps(bytes: intervalBytes, seconds: intervalDuration) }

    public init(offset: Double, intervalDuration: Double, intervalBytes: Int64, cumulativeBytes: Int64, activeStreams: Int) {
        self.offset = offset
        self.intervalDuration = intervalDuration
        self.intervalBytes = intervalBytes
        self.cumulativeBytes = cumulativeBytes
        self.activeStreams = activeStreams
    }
}

/// Aggregated throughput statistics.
public struct SpeedSummary: Codable, Sendable, Hashable {
    /// Time-weighted average over the steady-state window.
    public var averageMbps: Double
    /// Highest rolling-window average (see `SpeedCalculator.summarize`).
    public var peakMbps: Double
    /// Lowest interval throughput in the steady-state window.
    public var minimumMbps: Double
    public var medianMbps: Double
    /// 95th percentile of interval throughput.
    public var p95Mbps: Double
    /// 10th percentile — the "sustained" rate the link held 90 % of the time.
    public var p10Mbps: Double
    public var stability: StabilityMetrics
    /// Total bytes moved (including warm-up).
    public var totalBytes: Int64
    /// Total transfer duration in seconds (including warm-up).
    public var duration: Double
    /// Samples excluded as warm-up (TCP slow start / stream ramp-up).
    public var warmupSampleCount: Int
}

/// Complete result of one direction of a speed test.
public struct SpeedResult: Codable, Sendable, Hashable {
    public var direction: TransferDirection
    /// Full timeline — never discarded, so charts and exports show the real behaviour.
    public var samples: [SpeedSample]
    public var summary: SpeedSummary
    /// Stream count history: (offset, streams) whenever the adaptive policy changed it.
    public var streamChanges: [StreamChange]
    /// True when the test was stopped before its planned duration.
    public var wasCancelled: Bool

    public init(direction: TransferDirection, samples: [SpeedSample], summary: SpeedSummary, streamChanges: [StreamChange], wasCancelled: Bool) {
        self.direction = direction
        self.samples = samples
        self.summary = summary
        self.streamChanges = streamChanges
        self.wasCancelled = wasCancelled
    }
}

public struct StreamChange: Codable, Sendable, Hashable {
    public var offset: Double
    public var streams: Int
    public init(offset: Double, streams: Int) {
        self.offset = offset
        self.streams = streams
    }
}

/// Converts a raw timeline into summary statistics.
public enum SpeedCalculator {

    /// Summarises a timeline.
    ///
    /// Steady state: samples whose `offset` is greater than `warmupDuration` (TCP slow start and
    /// stream ramp-up would otherwise drag the average down). If no sample survives, all samples
    /// are used.
    ///
    ///     average  = Σ intervalBytes(steady) × 8 / Σ intervalDuration(steady) / 10⁶
    ///                (time-weighted; robust to uneven sampling intervals)
    ///     peak     = max over steady samples of the trailing moving average of `peakWindow`
    ///                interval rates (rejects single-interval timer artefacts)
    ///     minimum  = min interval rate in steady state
    ///     median / P95 / P10 = `Percentile` over steady interval rates
    ///     stability = `StabilityCalculator.evaluate` over steady interval rates
    public static func summarize(samples: [SpeedSample], warmupDuration: Double = 1.0, peakWindow: Int = 3) -> SpeedSummary {
        let totalBytes = samples.last?.cumulativeBytes ?? samples.reduce(0) { $0 + $1.intervalBytes }
        let duration = samples.last?.offset ?? 0

        var steady = samples.filter { $0.offset > warmupDuration }
        if steady.isEmpty { steady = samples }
        let warmupCount = samples.count - steady.count

        guard !steady.isEmpty else {
            return SpeedSummary(averageMbps: 0, peakMbps: 0, minimumMbps: 0, medianMbps: 0, p95Mbps: 0, p10Mbps: 0,
                                stability: .undefined, totalBytes: totalBytes, duration: duration, warmupSampleCount: 0)
        }

        let steadyBytes = steady.reduce(Int64(0)) { $0 + $1.intervalBytes }
        let steadyDuration = steady.reduce(0.0) { $0 + $1.intervalDuration }
        let rates = steady.map(\.mbps)
        let sorted = rates.sorted()

        let window = max(1, min(peakWindow, rates.count))
        let peak = Descriptive.movingAverage(rates, window: window).max() ?? sorted.last!

        return SpeedSummary(
            averageMbps: SpeedMath.mbps(bytes: steadyBytes, seconds: steadyDuration),
            peakMbps: peak,
            minimumMbps: sorted.first!,
            medianMbps: Percentile.value(0.5, sorted: sorted)!,
            p95Mbps: Percentile.value(0.95, sorted: sorted)!,
            p10Mbps: Percentile.value(0.10, sorted: sorted)!,
            stability: StabilityCalculator.evaluate(rates),
            totalBytes: totalBytes,
            duration: duration,
            warmupSampleCount: warmupCount)
    }
}
