import Foundation
import ChaiNetCore

/// A round-trip-time probe. Implementations: HTTP, TCP connect, UDP echo, ICMP echo.
///
/// `probe` must be safe to call concurrently (fixed-rate tests overlap probes) and must honour
/// task cancellation.
public protocol LatencyProbe: Sendable {
    var method: EndpointProbeMethod { get }
    var targetDescription: String { get }
    /// Opens sockets / warms connections. Called once before probing.
    func prepare() async throws
    /// Returns the RTT in milliseconds, or `nil` if the probe was lost / timed out.
    func probe(sequence: Int, timeout: Double) async -> Double?
    func close() async
}

/// Schedules probes at a fixed rate.
///
/// Probe *i* is sent at `i × interval` seconds after start regardless of previous replies
/// (open-loop), so a slow reply never delays the schedule — like a game or VoIP stream.
public enum LatencySampler {

    public static func stream(probe: any LatencyProbe, count: Int?, interval: Double, timeout: Double) -> AsyncStream<LatencySample> {
        AsyncStream { continuation in
            let task = Task {
                let stopwatch = Stopwatch()
                await withTaskGroup(of: Void.self) { group in
                    var i = 0
                    while count.map({ i < $0 }) ?? true, !Task.isCancelled {
                        do { try await sleepUntil(Double(i) * interval, since: stopwatch) } catch { break }
                        let seq = i
                        let offset = stopwatch.elapsed
                        group.addTask {
                            let rtt = await probe.probe(sequence: seq, timeout: timeout)
                            // A probe cancelled mid-flight is not a network loss; don't report it.
                            if Task.isCancelled { return }
                            continuation.yield(LatencySample(sequence: seq, offset: offset, rttMs: rtt))
                        }
                        i += 1
                    }
                    await group.waitForAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collects `count` samples (sorted by sequence). Cancellation returns what was collected.
    public static func collect(probe: any LatencyProbe, count: Int, interval: Double, timeout: Double,
                               onSample: (@Sendable (LatencySample) -> Void)? = nil) async -> [LatencySample] {
        var samples: [LatencySample] = []
        for await s in stream(probe: probe, count: count, interval: interval, timeout: timeout) {
            samples.append(s)
            onSample?(s)
        }
        return samples.sorted { $0.sequence < $1.sequence }
    }
}

/// Tracks in-flight probes for socket-based probes that match replies by sequence number.
final class PendingProbes: @unchecked Sendable {
    private struct Entry {
        var sentAt: ContinuousClock.Instant
        var continuation: CheckedContinuation<Double?, Never>
    }
    private let state = LockedValue<[UInt32: Entry]>([:])

    /// Registers the probe, runs `send`, and waits for `resolve(sequence:)` or the timeout.
    func waitForReply(sequence: UInt32, timeout: Double, send: @escaping @Sendable () -> Void) async -> Double? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
                state.withLock { $0[sequence] = Entry(sentAt: .now, continuation: cont) }
                send()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.expire(sequence: sequence)
                }
            }
        } onCancel: {
            self.expire(sequence: sequence)
        }
    }

    /// Called when a reply arrives. Returns false for unknown / late replies.
    @discardableResult
    func resolve(sequence: UInt32, at instant: ContinuousClock.Instant = .now) -> Bool {
        guard let entry = state.withLock({ $0.removeValue(forKey: sequence) }) else { return false }
        entry.continuation.resume(returning: (instant - entry.sentAt).milliseconds)
        return true
    }

    func expire(sequence: UInt32) {
        guard let entry = state.withLock({ $0.removeValue(forKey: sequence) }) else { return }
        entry.continuation.resume(returning: nil)
    }

    func expireAll() {
        let entries = state.withLock { d -> [Entry] in
            let all = Array(d.values)
            d.removeAll()
            return all
        }
        for e in entries { e.continuation.resume(returning: nil) }
    }
}
