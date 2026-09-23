import Foundation
import ChaiNetCore

/// Display-only smoothing for throughput charts. Measurements and exports keep raw samples.
enum SpeedSmoothing {
    /// Trailing moving average over `window` samples, time-weighted:
    ///
    ///     rateᵢ = Σ bytes(i−w+1 … i) × 8 / Σ duration(i−w+1 … i)
    ///
    /// Upload progress is reported by iOS in bursts (socket buffer flushes), so single 100 ms
    /// intervals swing between 0 and the burst rate; averaging over 0.5 s shows the real rate.
    static func movingAverage(_ samples: [SpeedSample], window: Int) -> [SpeedSample] {
        guard window > 1, samples.count > 1 else { return samples }
        var out: [SpeedSample] = []
        out.reserveCapacity(samples.count)
        var bytes: Int64 = 0
        var duration = 0.0
        for (i, s) in samples.enumerated() {
            bytes += s.intervalBytes
            duration += s.intervalDuration
            if i >= window {
                bytes -= samples[i - window].intervalBytes
                duration -= samples[i - window].intervalDuration
            }
            // Keep `mbps` = bytes / duration by scaling the window to a 1-interval sample.
            let scaledBytes = duration > 0 ? Int64(Double(bytes) * s.intervalDuration / duration) : 0
            out.append(SpeedSample(offset: s.offset, intervalDuration: s.intervalDuration, intervalBytes: scaledBytes,
                                   cumulativeBytes: s.cumulativeBytes, activeStreams: s.activeStreams))
        }
        return out
    }
}
