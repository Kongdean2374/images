import Foundation
import ChaiNetCore

/// Measurement Lab NDT7 client (https://github.com/m-lab/ndt-server/blob/main/spec/ndt7-protocol.md).
///
/// - Locate API picks the nearest healthy machine and returns short-lived, access-token URLs:
///   `GET https://locate.measurementlab.net/v2/nearest/ndt/ndt7` → `results[].urls["wss:///ndt/v7/download"]`.
/// - One WebSocket (`Sec-WebSocket-Protocol: net.measurementlab.ndt.v7`), i.e. a single TCP
///   stream by design; each transfer is capped at 10 s by the protocol.
/// - Download: every received message (binary data or JSON measurement text) is counted and
///   discarded. Upload: random in-memory binary messages; size starts at 8 KiB and doubles while
///   total sent ≥ 16 × size, up to 1 MiB (the protocol's scaling rule).
/// - The same 100 ms sampler / `SpeedCalculator` as the HTTP engine, so results are comparable.
public struct NDT7SpeedTestEngine: SpeedTestEngineProtocol {
    public static let subprotocol = "net.measurementlab.ndt.v7"
    public static let maxSeconds = 10.0

    public struct Target: Sendable, Hashable {
        public var machine: String
        public var city: String?
        public var downloadURL: URL
        public var uploadURL: URL
    }

    public init() {}

    struct LocateResponse: Decodable {
        struct Result: Decodable {
            struct Location: Decodable { var city: String?; var country: String? }
            var machine: String
            var location: Location?
            var urls: [String: String]
        }
        var results: [Result]
    }

    /// Nearest machine via the Locate API (fresh tokens each call — tokens are single-use / short-lived).
    public static func locate(_ url: URL = ServerDescriptor.mlabNDT7.baseURL, timeout: Double = 8) async throws -> Target {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EngineError.server("M-Lab Locate HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let decoded = try JSONDecoder().decode(LocateResponse.self, from: data)
        for r in decoded.results {
            if let d = r.urls["wss:///ndt/v7/download"].flatMap(URL.init(string:)),
               let u = r.urls["wss:///ndt/v7/upload"].flatMap(URL.init(string:)) {
                return Target(machine: r.machine, city: r.location?.city, downloadURL: d, uploadURL: u)
            }
        }
        throw EngineError.server("M-Lab Locate 沒有可用節點")
    }

    public func run(_ c: SpeedTestConfiguration) -> AsyncThrowingStream<SpeedTestEvent, Error> {
        makeCancellableStream { continuation in
            let target = try await Self.locate(c.server.baseURL)
            let url = c.direction == .download ? target.downloadURL : target.uploadURL
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let ws = session.webSocketTask(with: url, protocols: [Self.subprotocol])
            ws.maximumMessageSize = 1 << 24
            ws.resume()

            let counter = ByteCounter()
            let finished = LockedValue<Error?>(nil)
            let ioDone = LockedValue(false)
            let direction = c.direction
            let io = Task {
                do {
                    if direction == .download {
                        while !Task.isCancelled {
                            switch try await ws.receive() {
                            case .data(let d): counter.add(Int64(d.count))
                            case .string(let s): counter.add(Int64(s.utf8.count))
                            @unknown default: break
                            }
                        }
                    } else {
                        // Drain server measurement messages so they never back up.
                        let drain = Task { while !Task.isCancelled { _ = try? await ws.receive() } }
                        defer { drain.cancel() }
                        let payload = UploadPayload.make(bytes: 1 << 20)
                        var size = 1 << 13
                        var sent: Int64 = 0
                        while !Task.isCancelled {
                            try await ws.send(.data(payload.prefix(size)))
                            counter.add(Int64(size))
                            sent += Int64(size)
                            if size < (1 << 20) && sent >= Int64(16 * size) { size *= 2 }
                        }
                    }
                } catch {
                    finished.withLock { $0 = error }
                }
                ioDone.withLock { $0 = true }
            }
            defer {
                io.cancel()
                ws.cancel(with: .normalClosure, reason: nil)
            }
            continuation.yield(.streamsChanged(1))

            let duration = min(c.maxDuration, Self.maxSeconds)
            let stopwatch = Stopwatch()
            var samples: [SpeedSample] = []
            var last: Int64 = 0
            var lastOffset = 0.0
            var i = 1
            while stopwatch.elapsed < duration {
                try await sleepUntil(Double(i) * c.sampleInterval, since: stopwatch)
                try Task.checkCancellation()
                let now = stopwatch.elapsed
                let total = counter.total
                let s = SpeedSample(offset: now, intervalDuration: now - lastOffset, intervalBytes: total - last, cumulativeBytes: total,
                                    activeStreams: 1)
                samples.append(s)
                continuation.yield(.sample(s))
                last = total
                lastOffset = now
                i += 1
                if let cap = c.byteCap, total >= cap { break }
                // Server closes the socket when its 10 s are up (download) — stop sampling then.
                if ioDone.current { break }
            }
            if samples.allSatisfy({ $0.cumulativeBytes == 0 }), let error = finished.current {
                throw EngineError.server("NDT7 \(target.machine)：\(error.localizedDescription)")
            }
            let summary = SpeedCalculator.summarize(samples: samples, warmupDuration: c.warmupDuration)
            continuation.yield(.completed(SpeedResult(direction: c.direction, samples: samples, summary: summary,
                                                      streamChanges: [StreamChange(offset: 0, streams: 1)], wasCancelled: false)))
        }
    }
}
