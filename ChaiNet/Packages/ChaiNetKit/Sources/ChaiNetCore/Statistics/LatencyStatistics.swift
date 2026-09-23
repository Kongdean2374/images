import Foundation

/// One latency probe result.
public struct LatencySample: Codable, Sendable, Hashable, Identifiable {
    /// Sequence number in send order (0-based).
    public var sequence: Int
    /// Seconds since the start of the measurement when the probe was sent.
    public var offset: Double
    /// Round-trip time in milliseconds, or `nil` if the probe was lost / timed out.
    public var rttMs: Double?

    public var id: Int { sequence }
    public var isLost: Bool { rttMs == nil }

    public init(sequence: Int, offset: Double, rttMs: Double?) {
        self.sequence = sequence
        self.offset = offset
        self.rttMs = rttMs
    }
}

/// Summary of the RTTs of received probes. Only exists when at least one probe was received.
public struct RTTSummary: Codable, Sendable, Hashable {
    public var minimum: Double
    public var average: Double
    public var median: Double
    public var maximum: Double
    public var p95: Double
    public var p99: Double
    /// Mean absolute consecutive difference (see `Jitter.meanConsecutiveDifference`). 0 with one sample.
    public var jitter: Double
    /// RFC 3550 smoothed jitter. 0 with one sample.
    public var jitterRFC3550: Double
    /// Population standard deviation of RTT.
    public var standardDeviation: Double
}

/// Complete latency statistics for a probe run: RTT distribution + loss analysis.
public struct LatencyStatistics: Codable, Sendable, Hashable {
    public var rtt: RTTSummary?
    public var loss: LossAnalysis

    public var sent: Int { loss.sent }
    public var received: Int { loss.received }

    public init(rtt: RTTSummary?, loss: LossAnalysis) {
        self.rtt = rtt
        self.loss = loss
    }

    /// Computes statistics from samples. Samples are ordered by `sequence` first so jitter is
    /// computed in send order even if replies arrived out of order.
    ///
    /// - minimum / maximum: extreme RTTs of received probes
    /// - average: arithmetic mean
    /// - median, P95, P99: `Percentile` (type 7 linear interpolation)
    /// - jitter: `Jitter.meanConsecutiveDifference` over received probes in send order
    /// - loss: `PacketLossAnalyzer` over the full send sequence
    public static func compute(from samples: [LatencySample], burstThreshold: Int = 2) -> LatencyStatistics {
        let ordered = samples.sorted { $0.sequence < $1.sequence }
        let loss = PacketLossAnalyzer.analyze(received: ordered.map { !$0.isLost }, burstThreshold: burstThreshold)
        let rtts = ordered.compactMap(\.rttMs)
        guard !rtts.isEmpty else { return LatencyStatistics(rtt: nil, loss: loss) }

        let sorted = rtts.sorted()
        let summary = RTTSummary(
            minimum: sorted.first!,
            average: Descriptive.mean(rtts)!,
            median: Percentile.value(0.5, sorted: sorted)!,
            maximum: sorted.last!,
            p95: Percentile.value(0.95, sorted: sorted)!,
            p99: Percentile.value(0.99, sorted: sorted)!,
            jitter: Jitter.meanConsecutiveDifference(rtts) ?? 0,
            jitterRFC3550: Jitter.rfc3550(rtts) ?? 0,
            standardDeviation: Descriptive.populationStandardDeviation(rtts) ?? 0)
        return LatencyStatistics(rtt: summary, loss: loss)
    }
}
