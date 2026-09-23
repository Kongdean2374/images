import Foundation
import ChaiNetCore

/// HTTP request/response latency on a warm (keep-alive) connection.
///
/// Measures request start → response end with a monotonic clock. Because it runs over TCP it
/// can't observe packet loss (TCP retransmits); a timeout counts as lost.
public final class HTTPLatencyProbe: LatencyProbe, @unchecked Sendable {
    public let url: URL
    public let method: EndpointProbeMethod = .httpPing
    public var targetDescription: String { url.host() ?? url.absoluteString }
    private let session: URLSession

    public init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 5
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func request(sequence: Int, timeout: Double) -> URLRequest {
        var req = URLRequest(url: url.appending(queryItems: [URLQueryItem(name: "seq", value: String(sequence))]))
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = timeout
        return req
    }

    public func prepare() async throws {
        // Warm-up: DNS + TCP + TLS happen here so probes measure only the round trip.
        _ = try await session.data(for: request(sequence: -1, timeout: 5))
    }

    public func probe(sequence: Int, timeout: Double) async -> Double? {
        let stopwatch = Stopwatch()
        do {
            let (_, response) = try await session.data(for: request(sequence: sequence, timeout: timeout))
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
            return stopwatch.elapsedMs
        } catch {
            return nil
        }
    }

    public func close() async {
        session.invalidateAndCancel()
    }
}
