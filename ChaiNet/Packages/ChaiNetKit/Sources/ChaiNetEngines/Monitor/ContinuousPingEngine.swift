import Foundation
import ChaiNetCore

public enum MonitorEvent: Sendable {
    case sample(LatencySample)
    case spike(LatencySpikeEvent)
    case dropStarted(NetworkDropEvent)
    case dropEnded(NetworkDropEvent)
    case pathChanged(PathChangeEvent)
}

public protocol ContinuousPingEngineProtocol: Sendable {
    /// Open-ended monitoring; stops when the consumer stops iterating (or `duration` elapses).
    func run(probe: any LatencyProbe, interval: Double, duration: Double?) -> AsyncThrowingStream<MonitorEvent, Error>
}

/// Continuous ping with online spike / drop detection and path-change tracking.
///
/// iOS limits background execution: monitoring only runs while the app is in the foreground
/// (the app stops it when entering background). Background checks are separate, short,
/// system-scheduled BGAppRefresh tasks.
public struct ContinuousPingEngine: ContinuousPingEngineProtocol {
    public var networkInfo: any NetworkInfoProviding

    public init(networkInfo: any NetworkInfoProviding = NetworkInfoProvider()) {
        self.networkInfo = networkInfo
    }

    public func run(probe: any LatencyProbe, interval: Double, duration: Double?) -> AsyncThrowingStream<MonitorEvent, Error> {
        let info = networkInfo
        return makeCancellableStream { continuation in
            try await withTimeout(10) { try await probe.prepare() }
            let stopwatch = Stopwatch()
            let pathTask = Task {
                var last: (InterfaceKind, PathStatus)?
                for await snap in info.pathUpdates() {
                    let current = (snap.primaryInterface, snap.status)
                    if let last, last == current { continue }
                    if last != nil {
                        continuation.yield(.pathChanged(PathChangeEvent(offset: stopwatch.elapsed, interface: snap.primaryInterface, status: snap.status)))
                    }
                    last = current
                }
            }
            defer { pathTask.cancel() }

            var spikes = LatencySpikeDetector()
            var drops = NetworkDropDetector()
            // Samples are emitted in completion order; the detectors need send order, so a
            // small reorder buffer releases samples strictly by sequence.
            var buffer: [Int: LatencySample] = [:]
            var next = 0
            let count = duration.map { Int(($0 / interval).rounded(.up)) }
            for await sample in LatencySampler.stream(probe: probe, count: count, interval: interval, timeout: min(2, max(interval, 1))) {
                buffer[sample.sequence] = sample
                while let s = buffer.removeValue(forKey: next) {
                    next += 1
                    continuation.yield(.sample(s))
                    if let rtt = s.rttMs, let spike = spikes.ingest(sequence: s.sequence, offset: s.offset, rttMs: rtt) {
                        continuation.yield(.spike(spike))
                    }
                    switch drops.ingest(s) {
                    case .started(let d)?: continuation.yield(.dropStarted(d))
                    case .ended(let d)?: continuation.yield(.dropEnded(d))
                    case nil: break
                    }
                }
            }
            _ = try? await withDeadline(3, fallback: ()) { await probe.close() }
            try Task.checkCancellation()
        }
    }
}
