import Foundation

/// A latency spike detected by `LatencySpikeDetector`.
public struct LatencySpikeEvent: Codable, Sendable, Hashable {
    public var sequence: Int
    public var offset: Double
    public var rttMs: Double
    /// Baseline median at the time of detection.
    public var baselineMs: Double
    /// Threshold that was exceeded.
    public var thresholdMs: Double
}

/// Online latency-spike detector using a rolling median and MAD.
///
///     baseline  = median(window)
///     σ̂         = 1.4826 × MAD(window)                (robust σ estimate)
///     threshold = baseline + max(minimumIncreaseMs, k × σ̂)
///     spike     ⇔ rtt > threshold
///
/// Default: window 30, k = 5, minimumIncreaseMs = 30, and no decision until 5 samples have been
/// seen. The absolute floor stops a perfectly flat baseline (MAD = 0) from flagging 1 ms noise.
public struct LatencySpikeDetector: Sendable {
    public var windowSize: Int
    public var madMultiplier: Double
    public var minimumIncreaseMs: Double
    public var minimumBaselineSamples: Int
    private var window: [Double] = []

    public init(windowSize: Int = 30, madMultiplier: Double = 5, minimumIncreaseMs: Double = 30, minimumBaselineSamples: Int = 5) {
        self.windowSize = max(3, windowSize)
        self.madMultiplier = madMultiplier
        self.minimumIncreaseMs = minimumIncreaseMs
        self.minimumBaselineSamples = max(1, minimumBaselineSamples)
    }

    /// Current threshold, or `nil` while the baseline is still being learned.
    public var currentThreshold: Double? {
        guard window.count >= minimumBaselineSamples,
              let baseline = Descriptive.median(window),
              let mad = Descriptive.medianAbsoluteDeviation(window) else { return nil }
        return baseline + max(minimumIncreaseMs, madMultiplier * 1.4826 * mad)
    }

    /// Feeds a sample. Lost samples should not be fed (handled by `NetworkDropDetector`).
    public mutating func ingest(sequence: Int, offset: Double, rttMs: Double) -> LatencySpikeEvent? {
        var event: LatencySpikeEvent?
        if let threshold = currentThreshold, rttMs > threshold, let baseline = Descriptive.median(window) {
            event = LatencySpikeEvent(sequence: sequence, offset: offset, rttMs: rttMs, baselineMs: baseline, thresholdMs: threshold)
        }
        window.append(rttMs)
        if window.count > windowSize { window.removeFirst(window.count - windowSize) }
        return event
    }
}

/// A period during which the network did not answer.
public struct NetworkDropEvent: Codable, Sendable, Hashable {
    /// Offset of the first lost probe of the outage.
    public var startOffset: Double
    /// Offset of the first probe answered after the outage (nil while still ongoing).
    public var endOffset: Double?
    /// Consecutive probes lost.
    public var lostProbes: Int

    public var duration: Double? { endOffset.map { $0 - startOffset } }
}

public enum NetworkDropTransition: Sendable, Hashable {
    case started(NetworkDropEvent)
    case ended(NetworkDropEvent)
}

/// Detects outages from a probe stream.
///
/// A drop *starts* when `consecutiveLossThreshold` probes in a row are lost (default 3, i.e.
/// ≈3 s at 1 Hz) and *ends* at the next received probe. Shorter loss runs are regular packet
/// loss and are reported by `PacketLossAnalyzer` instead.
public struct NetworkDropDetector: Sendable {
    public var consecutiveLossThreshold: Int
    private var lossRun = 0
    private var runStartOffset: Double?
    private var activeDrop: NetworkDropEvent?

    public init(consecutiveLossThreshold: Int = 3) {
        self.consecutiveLossThreshold = max(1, consecutiveLossThreshold)
    }

    public var isInDrop: Bool { activeDrop != nil }

    public mutating func ingest(_ sample: LatencySample) -> NetworkDropTransition? {
        if sample.isLost {
            if lossRun == 0 { runStartOffset = sample.offset }
            lossRun += 1
            if activeDrop == nil, lossRun >= consecutiveLossThreshold {
                let drop = NetworkDropEvent(startOffset: runStartOffset ?? sample.offset, endOffset: nil, lostProbes: lossRun)
                activeDrop = drop
                return .started(drop)
            }
            activeDrop?.lostProbes = lossRun
            return nil
        }
        defer { lossRun = 0; runStartOffset = nil }
        if var drop = activeDrop {
            drop.endOffset = sample.offset
            drop.lostProbes = lossRun
            activeDrop = nil
            return .ended(drop)
        }
        return nil
    }
}
