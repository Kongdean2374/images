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
    /// Samples excluded from statistics (warm-up + stream-count transitions).
    public var warmupSampleCount: Int
    /// Of which excluded because they fell inside a stream-count transition guard.
    public var transitionExcludedSampleCount: Int?
    /// Samples per analysis window (statistics are computed on windows, not raw 100 ms samples).
    public var windowSamples: Int?
    /// Number of analysis windows the distribution statistics are based on.
    public var analysisWindowCount: Int?
    /// The analysis-window rates (Mbps) behind median / P95 / P10 / min / peak / stability.
    /// Reports print exactly these values so statistics and raw data can be cross-checked.
    public var analysisWindowMbps: [Double]?
    /// Warm-up used for this summary (so it can be reproduced exactly).
    public var warmupDuration: Double?
    /// True when the raw counter showed callback / buffer batching (see `SpeedCalculator.batching`).
    public var samplingArtifactDetected: Bool?
    /// Share of steady 100 ms intervals that reported zero bytes.
    public var zeroIntervalFraction: Double?

    /// False when the timeline shows progress-reporting batching: short-window statistics
    /// (P10, minimum, peak, drop windows, stability) then describe the reporting cadence, not the
    /// network, and must not be used. Bytes / elapsed time (the average) stays valid.
    public var shortWindowReliable: Bool { samplingArtifactDetected != true }
    public var reliableP10Mbps: Double? { shortWindowReliable ? p10Mbps : nil }
    public var reliableMinimumMbps: Double? { shortWindowReliable ? minimumMbps : nil }
    public var reliablePeakMbps: Double? { shortWindowReliable ? peakMbps : nil }
    public var reliableStabilityScore: Double? { shortWindowReliable ? stability.score : nil }
    public var reliableDropCount: Int? { shortWindowReliable ? stability.dropCount : nil }
    /// "measurementSamplingArtifact" when stability is unavailable because of batching.
    public var stabilityUnavailableReason: String? { shortWindowReliable ? nil : "measurementSamplingArtifact" }
    /// Sustained rate: P10 of windows when reliable, else the byte-count average.
    public var sustainedMbps: Double { shortWindowReliable ? p10Mbps : averageMbps }
    /// Robust central rate: window median when reliable, else bytes / elapsed time.
    public var robustMbps: Double { shortWindowReliable ? medianMbps : averageMbps }

    /// Human-readable statement of how the statistics were computed.
    public var methodDescription: String {
        let w = windowSamples ?? 1
        let artifact = samplingArtifactDetected == true
            ? "偵測到回報批次化（\(Int(((zeroIntervalFraction ?? 0) * 100).rounded()))% 的 100 ms 區間為 0），視窗已放大；" : ""
        return artifact + "統計基於穩態 \(analysisWindowCount ?? 0) 個時間加權視窗（每視窗 \(w) 個 100 ms 樣本）；"
            + "已排除暖機與平行連線數變更期間 \(warmupSampleCount) 個樣本（其中連線變更 \(transitionExcludedSampleCount ?? 0) 個）。"
    }
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
    /// HTTP status / content type / payload / per-stream counters (nil in older results and mocks).
    public var diagnostics: TransferDiagnostics?
    /// Whether this transfer produced a real, usable measurement (nil = not validated, treated valid).
    public var validity: TransferValidity?

    public var isValid: Bool { validity?.valid ?? true }

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

    /// Default analysis window: 5 × 100 ms = 0.5 s.
    public static let defaultWindowSamples = 5
    /// Upper bound of the adaptive window: 20 × 100 ms = 2 s.
    public static let maximumWindowSamples = 20

    /// Detects progress-reporting batching.
    ///
    /// URLSession reports upload progress when data is copied into the socket buffer, so on
    /// fast / buffered links the 100 ms counter alternates between 0 and a burst (e.g.
    /// 0, 0, 0, 1361 Mbps). Those zeros are not the radio stopping. If more than 20 % of steady
    /// intervals are zero (in at least 3 separate runs), the window is widened to cover the typical batching period:
    ///
    ///     gap    = median length of runs of zero intervals
    ///     window = clamp(2 × (gap + 1), 5, 20) samples           (0.5 s … 2 s)
    ///
    /// The median (not the maximum) is used so a genuine multi-second outage does not widen the
    /// window — outages longer than the window still appear as low windows.
    public static func batching(_ steady: [SpeedSample]) -> (windowSamples: Int, detected: Bool, zeroFraction: Double) {
        guard !steady.isEmpty else { return (defaultWindowSamples, false, 0) }
        let zeroFraction = Double(steady.filter { $0.intervalBytes == 0 }.count) / Double(steady.count)
        guard zeroFraction > 0.2 else { return (defaultWindowSamples, false, zeroFraction) }
        var runs: [Double] = []
        var run = 0
        for s in steady {
            if s.intervalBytes == 0 { run += 1 } else if run > 0 { runs.append(Double(run)); run = 0 }
        }
        if run > 0 { runs.append(Double(run)) }
        // Batching is a repeating pattern; one long zero run is a real outage and must stay visible.
        guard runs.count >= 3 else { return (defaultWindowSamples, false, zeroFraction) }
        let gap = Descriptive.median(runs) ?? 0
        let window = Int(min(Double(maximumWindowSamples), max(Double(defaultWindowSamples), 2 * (gap + 1))).rounded(.up))
        return (window, true, zeroFraction)
    }
    /// Seconds after a stream-count change during which samples are excluded.
    public static let defaultTransitionGuard = 1.0

    /// Steady-state samples.
    ///
    /// A sample (interval `(offset − duration, offset]`) is excluded when
    ///
    ///     offset ≤ warmupDuration                                 (TCP slow start)
    ///     or it overlaps (change.offset, change.offset + guard]   for any stream-count change
    ///                                                             after t = 0 (new streams ramping)
    ///
    /// so the adaptive test's own stream additions are never mistaken for network instability.
    /// If nothing survives, all samples are used.
    public static func steadyState(_ samples: [SpeedSample], streamChanges: [StreamChange], warmupDuration: Double,
                                   transitionGuard: Double) -> (steady: [SpeedSample], warmupExcluded: Int, transitionExcluded: Int) {
        let transitions = streamChanges.map(\.offset).filter { $0 > 0 }
        var steady: [SpeedSample] = []
        var warm = 0, trans = 0
        for s in samples {
            let eps = 1e-6   // sample offsets are accumulated floating-point times
            if s.offset <= warmupDuration + eps { warm += 1; continue }
            let start = s.offset - s.intervalDuration
            if transitions.contains(where: { s.offset > $0 + eps && start < $0 + transitionGuard - eps }) { trans += 1; continue }
            steady.append(s)
        }
        if steady.isEmpty { return (samples, 0, 0) }
        return (steady, warm, trans)
    }

    /// Groups consecutive steady samples into windows of `windowSamples` and returns the
    /// time-weighted rate of each window:
    ///
    ///     rate(window) = Σ bytes × 8 / Σ duration / 10⁶
    ///
    /// Windows never span a gap (an excluded region); a trailing partial window is kept when it
    /// has at least half the nominal sample count.
    public static func windowRates(_ steady: [SpeedSample], windowSamples: Int) -> [Double] {
        let w = max(1, windowSamples)
        var rates: [Double] = []
        var current: [SpeedSample] = []
        func rate(_ group: [SpeedSample]) -> Double {
            SpeedMath.mbps(bytes: group.reduce(0) { $0 + $1.intervalBytes }, seconds: group.reduce(0) { $0 + $1.intervalDuration })
        }
        func close() {
            if !current.isEmpty, current.count * 2 >= w { rates.append(rate(current)) }
            current = []
        }
        for s in steady {
            if let last = current.last, s.offset - s.intervalDuration > last.offset + s.intervalDuration * 0.5 {
                close()   // gap (excluded region) — windows never span it
            }
            current.append(s)
            if current.count == w {
                rates.append(rate(current))
                current = []
            }
        }
        close()
        return rates
    }

    /// Summarises a timeline.
    ///
    ///     average   = Σ bytes(steady) × 8 / Σ duration(steady) / 10⁶     (time-weighted)
    ///     windows   = windowRates(steady, windowSamples)                   (0.5 s by default)
    ///     peak      = max(windows)
    ///     minimum   = min(windows)
    ///     median / P95 / P10 = Percentile(windows)
    ///     stability = StabilityCalculator.evaluate(windows)
    ///
    /// Statistics use 0.5 s windows rather than raw 100 ms samples because transfer progress is
    /// reported in bursts (upload socket-buffer flushes), which makes single 100 ms intervals
    /// swing between 0 and the burst rate and would make the median 0 on a working link.
    ///
    /// `windowSamples` nil (default) = adaptive (`batching`); pass a value to force a window.
    public static func summarize(samples: [SpeedSample], streamChanges: [StreamChange] = [], warmupDuration: Double = 1.0,
                                 transitionGuard: Double = defaultTransitionGuard,
                                 windowSamples requestedWindow: Int? = nil) -> SpeedSummary {
        let totalBytes = samples.last?.cumulativeBytes ?? samples.reduce(0) { $0 + $1.intervalBytes }
        let duration = samples.last?.offset ?? 0
        guard !samples.isEmpty else {
            return SpeedSummary(averageMbps: 0, peakMbps: 0, minimumMbps: 0, medianMbps: 0, p95Mbps: 0, p10Mbps: 0,
                                stability: .undefined, totalBytes: totalBytes, duration: duration, warmupSampleCount: 0,
                                transitionExcludedSampleCount: 0, windowSamples: requestedWindow ?? defaultWindowSamples,
                                analysisWindowCount: 0, analysisWindowMbps: [], warmupDuration: warmupDuration)
        }
        let (steady, warm, trans) = steadyState(samples, streamChanges: streamChanges, warmupDuration: warmupDuration,
                                                transitionGuard: transitionGuard)
        let detection = batching(steady)
        let windowSamples = requestedWindow ?? detection.windowSamples
        var windows = windowRates(steady, windowSamples: windowSamples)
        if windows.isEmpty { windows = windowRates(steady, windowSamples: 1) }

        let steadyBytes = steady.reduce(Int64(0)) { $0 + $1.intervalBytes }
        let steadyDuration = steady.reduce(0.0) { $0 + $1.intervalDuration }
        let sorted = windows.sorted()

        return SpeedSummary(
            averageMbps: SpeedMath.mbps(bytes: steadyBytes, seconds: steadyDuration),
            peakMbps: sorted.last!,
            minimumMbps: sorted.first!,
            medianMbps: Percentile.value(0.5, sorted: sorted)!,
            p95Mbps: Percentile.value(0.95, sorted: sorted)!,
            p10Mbps: Percentile.value(0.10, sorted: sorted)!,
            // Artifact-contaminated timelines (callback / chunk batching) can't support short-window
            // variability: stability is not computed rather than reported as a network problem.
            stability: requestedWindow == nil && detection.detected ? .undefined : StabilityCalculator.evaluate(windows),
            totalBytes: totalBytes,
            duration: duration,
            warmupSampleCount: warm + trans,
            transitionExcludedSampleCount: trans,
            windowSamples: windowSamples,
            analysisWindowCount: windows.count,
            analysisWindowMbps: windows,
            warmupDuration: warmupDuration,
            samplingArtifactDetected: requestedWindow == nil ? detection.detected : nil,
            zeroIntervalFraction: detection.zeroFraction)
    }
}
