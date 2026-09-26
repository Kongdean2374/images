import Foundation
import ChaiNetCore

public struct SpeedTestConfiguration: Sendable {
    public var server: ServerDescriptor
    public var direction: TransferDirection
    /// Hard stop (seconds).
    public var maxDuration: Double
    /// When set, the test may end early once throughput is steady (Auto duration).
    public var autoDuration: AutoDurationPolicy?
    /// Fixed stream count (Settings), or nil for adaptive 2/4/8/16.
    public var fixedStreams: Int?
    public var policy: StreamScalingPolicy
    /// Stop after this many bytes (traffic saver), nil = unlimited.
    public var byteCap: Int64?
    public var sampleInterval: Double
    public var warmupDuration: Double
    /// Bytes requested per download request / sent per upload request.
    public var chunkBytes: Int
    /// Stress loads: stop early (throw `EngineError.server("rateLimited …" / "stalled …")`) when the
    /// endpoint answers 429 / 403 or no byte moves for `stallAbortSeconds`, so the caller can switch node.
    public var abortWhenBlocked: Bool = false
    public var stallAbortSeconds: Double = 6

    public init(server: ServerDescriptor, direction: TransferDirection, maxDuration: Double = 12, autoDuration: AutoDurationPolicy? = nil,
                fixedStreams: Int? = nil, policy: StreamScalingPolicy = .default, byteCap: Int64? = nil,
                sampleInterval: Double = 0.1, warmupDuration: Double = 1.0, chunkBytes: Int? = nil) {
        self.server = server
        self.direction = direction
        self.maxDuration = maxDuration
        self.autoDuration = autoDuration
        self.fixedStreams = fixedStreams
        self.policy = policy
        self.byteCap = byteCap
        self.sampleInterval = sampleInterval
        self.warmupDuration = warmupDuration
        self.chunkBytes = chunkBytes ?? (direction == .download ? 25_000_000 : 4_000_000)
    }
}

public enum SpeedTestEvent: Sendable {
    case sample(SpeedSample)
    case streamsChanged(Int)
    case completed(SpeedResult)
}

public protocol SpeedTestEngineProtocol: Sendable {
    /// Runs one direction. Cancel by cancelling the consuming task / stopping iteration.
    func run(_ configuration: SpeedTestConfiguration) -> AsyncThrowingStream<SpeedTestEvent, Error>
}

/// Multi-stream HTTP throughput engine.
///
/// - Each stream loops: download `chunkBytes` (bytes counted and discarded) or upload a
///   memory-generated random payload, until the test stops.
/// - A sampler reads the shared byte counter every `sampleInterval` and records a
///   `SpeedSample` (the full timeline is kept).
/// - Adaptive streams: every second during the ramp-up window (first 40 % of `maxDuration`,
///   at most 5 s) the policy is re-evaluated with the throughput of the last second and
///   streams are added (2 → 4 → 8 → 16), never removed.
/// - Stops at `maxDuration`, when `autoDuration` sees a steady state, or at `byteCap`.
public struct URLSessionSpeedTestEngine: SpeedTestEngineProtocol {
    public init() {}

    public func run(_ configuration: SpeedTestConfiguration) -> AsyncThrowingStream<SpeedTestEvent, Error> {
        makeCancellableStream { continuation in
            let result = try await Self.execute(configuration) { continuation.yield($0) }
            continuation.yield(.completed(result))
        }
    }

    static func execute(_ c: SpeedTestConfiguration, emit: @escaping @Sendable (SpeedTestEvent) -> Void) async throws -> SpeedResult {
        let counter = ByteCounter()
        let collector = TransferCollector(isDownload: c.direction == .download, expectedBytes: Int64(c.chunkBytes))
        let payload: Data? = c.direction == .upload ? UploadPayload.make(bytes: c.chunkBytes) : nil
        let streams = LockedValue<[TransferStream]>([])
        let stopwatch = Stopwatch()

        var request: URLRequest
        switch c.direction {
        case .download:
            request = URLRequest(url: c.server.downloadURL(bytes: c.chunkBytes))
        case .upload:
            request = URLRequest(url: c.server.uploadURL())
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let baseRequest = request

        // A stream keeps retrying (with back-off) for the whole test instead of giving up after a
        // few errors — otherwise a short outage left the rest of a long load at 0 Mbps.
        @Sendable func worker(_ stream: TransferStream) async {
            var failures = 0
            while !Task.isCancelled && !stream.isInvalidated {
                do {
                    try await stream.run(baseRequest, uploading: payload)
                    failures = 0
                } catch {
                    if Task.isCancelled || stream.isInvalidated { return }
                    failures += 1
                    try? await Task.sleep(for: .milliseconds(min(2_000, 150 * failures)))
                }
            }
        }

        var samples: [SpeedSample] = []
        var changes: [StreamChange] = []
        var activeCount = 0
        var cancelled = false
        var blocked: String?
        var stallRestarts = 0

        await withTaskGroup(of: Void.self) { group in
            func addStreams(to target: Int, at offset: Double) {
                guard target > activeCount else { return }
                for _ in activeCount..<target {
                    // Idle timeout (no data for this long fails the request so it is retried on a fresh connection).
                    let stream = TransferStream(counter: counter, timeout: min(max(4, c.maxDuration), 8), collector: collector)
                    streams.withLock { $0.append(stream) }
                    group.addTask { await worker(stream) }
                }
                activeCount = target
                changes.append(StreamChange(offset: offset, streams: target))
                emit(.streamsChanged(target))
            }

            addStreams(to: c.fixedStreams ?? c.policy.initialStreams, at: 0)

            var lastBytes: Int64 = 0
            var lastOffset = 0.0
            var lastProgress = 0.0, lastRestart = 0.0
            let stallSeconds = min(3, max(0.3, c.maxDuration * 0.2))
            var tick = 1
            let rampWindow = min(5, c.maxDuration * 0.4)
            var nextScaleCheck = 1.0

            while true {
                do {
                    try await sleepUntil(Double(tick) * c.sampleInterval, since: stopwatch)
                } catch {
                    cancelled = true
                    break
                }
                tick += 1
                let now = stopwatch.elapsed
                let bytes = counter.total
                let sample = SpeedSample(offset: now, intervalDuration: now - lastOffset, intervalBytes: bytes - lastBytes,
                                         cumulativeBytes: bytes, activeStreams: activeCount)
                samples.append(sample)
                emit(.sample(sample))
                if bytes > lastBytes { lastProgress = now }
                lastBytes = bytes
                lastOffset = now

                // Stall watchdog: no byte for a few seconds → rebuild every connection (new sockets).
                if now - lastProgress >= stallSeconds, now - lastRestart >= stallSeconds, now + stallSeconds < c.maxDuration {
                    let target = activeCount
                    for s in streams.current { s.invalidate() }
                    activeCount = 0
                    addStreams(to: target, at: now)
                    stallRestarts += 1
                    lastRestart = now
                }
                if c.abortWhenBlocked {
                    let d = collector.snapshot(perStreamBytes: [])
                    let refused = (d.statusCounts["429"] ?? 0) + (d.statusCounts["403"] ?? 0)
                    if refused >= 2, now - lastProgress >= min(1.5, stallSeconds) {
                        blocked = "rateLimited: HTTP \((d.statusCounts["429"] ?? 0) > 0 ? "429" : "403")"
                        break
                    }
                    if now - lastProgress >= min(c.stallAbortSeconds, c.maxDuration * 0.5), now >= 1 {
                        blocked = "stalled: no data for \(Int(now - lastProgress)) s"
                        break
                    }
                }

                if c.fixedStreams == nil, now >= nextScaleCheck, now <= rampWindow {
                    nextScaleCheck += 1
                    let recent = samples.filter { $0.offset > now - 1 }
                    let mbps = SpeedMath.mbps(bytes: recent.reduce(0) { $0 + $1.intervalBytes },
                                              seconds: recent.reduce(0) { $0 + $1.intervalDuration })
                    let next = c.policy.nextStreamCount(current: activeCount, measuredMbps: mbps)
                    addStreams(to: min(next, c.policy.maximumStreams), at: now)
                }

                if now >= c.maxDuration { break }
                if let cap = c.byteCap, bytes >= cap { break }
                if let auto = c.autoDuration {
                    let window = samples.suffix(auto.windowSamples).map(\.mbps)
                    if auto.shouldStop(elapsed: now, recentMbps: window) { break }
                }
            }
            group.cancelAll()
            for s in streams.current { s.invalidate() }
        }

        if cancelled || Task.isCancelled { throw CancellationError() }
        if let blocked { throw EngineError.server(blocked) }
        let summary = SpeedCalculator.summarize(samples: samples, streamChanges: changes, warmupDuration: c.warmupDuration)
        var result = SpeedResult(direction: c.direction, samples: samples, summary: summary, streamChanges: changes, wasCancelled: false)
        result.diagnostics = collector.snapshot(perStreamBytes: streams.current.map(\.bytes))
        if stallRestarts > 0 { result.diagnostics?.stallRestarts = stallRestarts }
        result.measurementSource = c.direction == .download
            ? "client_bytes_received (URLSessionDataDelegate)" : "client_write_completion (URLSessionTaskDelegate didSendBodyData)"
        result.validity = TransferValidator.evaluate(result)
        return result
    }
}
