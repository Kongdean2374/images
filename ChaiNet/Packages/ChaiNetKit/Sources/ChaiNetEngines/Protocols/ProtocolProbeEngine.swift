import Foundation
import Network
import ChaiNetCore

public protocol ProtocolProbeEngineProtocol: Sendable {
    func run(url: URL) async throws -> ProtocolProbeResult
}

/// Collects `URLSessionTaskMetrics` for one request.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let metrics = LockedValue<URLSessionTaskMetrics?>(nil)
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics.withLock { $0 = metrics }
    }
}

/// HTTP / TCP / TLS / TTFB / HTTP-2 / HTTP-3 / QUIC / IPv4 / IPv6 analysis of one host.
///
/// Timings come from `URLSessionTaskTransactionMetrics` of a request on a *fresh* ephemeral
/// session (so DNS, TCP and TLS are really performed):
///
///     dns  = domainLookupEnd − domainLookupStart
///     tcp  = connectEnd − connectStart − tls           (connect interval includes TLS on Darwin)
///     tls  = secureConnectionEnd − secureConnectionStart
///     ttfb = responseStart − requestStart
///     total= responseEnd − fetchStart
public struct ProtocolProbeEngine: ProtocolProbeEngineProtocol {
    public init() {}

    static func ms(_ a: Date?, _ b: Date?) -> Double? {
        guard let a, let b else { return nil }
        return b.timeIntervalSince(a) * 1000
    }

    static func breakdown(_ metrics: URLSessionTaskMetrics?, url: URL, status: Int?) -> HTTPTimingBreakdown? {
        guard let t = metrics?.transactionMetrics.last else { return nil }
        let tls = ms(t.secureConnectionStartDate, t.secureConnectionEndDate)
        let connect = ms(t.connectStartDate, t.connectEndDate)
        let tcp = connect.map { max(0, $0 - (tls ?? 0)) }
        let remote = t.remoteAddress
        let family: InterfaceAddress.Family? = remote.map { $0.contains(":") ? .ipv6 : .ipv4 }
        var tlsVersion: String?
        if let v = t.negotiatedTLSProtocolVersion {
            tlsVersion = switch v {
            case .TLSv13: "TLS 1.3"
            case .TLSv12: "TLS 1.2"
            default: "TLS (\(v.rawValue))"
            }
        }
        return HTTPTimingBreakdown(url: url.absoluteString, dnsMs: ms(t.domainLookupStartDate, t.domainLookupEndDate), tcpConnectMs: tcp,
                                   tlsMs: tls, ttfbMs: ms(t.requestStartDate, t.responseStartDate), totalMs: ms(t.fetchStartDate, t.responseEndDate),
                                   negotiatedProtocol: HTTPProtocolVersion(alpn: t.networkProtocolName), reusedConnection: t.isReusedConnection,
                                   remoteAddress: remote, localAddress: t.localAddress, ipFamily: family, tlsVersion: tlsVersion, statusCode: status)
    }

    /// One request on a brand-new session. With `http3`, the request is marked
    /// `assumesHTTP3Capable` and repeated so an Alt-Svc upgrade can take effect.
    public static func timedRequest(url: URL, http3: Bool) async throws -> HTTPTimingBreakdown? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var last: HTTPTimingBreakdown?
        for _ in 0..<(http3 ? 3 : 1) {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            if http3 { request.assumesHTTP3Capable = true }
            let collector = MetricsCollector()
            let (_, response) = try await session.data(for: request, delegate: collector)
            last = breakdown(collector.metrics.current, url: url, status: (response as? HTTPURLResponse)?.statusCode)
            if last?.negotiatedProtocol == .http3 { break }
        }
        return last
    }

    public func run(url: URL) async throws -> ProtocolProbeResult {
        let host = url.host() ?? ""
        let port = UInt16(url.port ?? 443)
        var errors: [String] = []

        var http: HTTPTimingBreakdown?
        do { http = try await Self.timedRequest(url: url, http3: false) } catch { errors.append("HTTP：\(error.localizedDescription)") }
        try Task.checkCancellation()

        var h3: HTTPTimingBreakdown?
        do { h3 = try await Self.timedRequest(url: url, http3: true) } catch { errors.append("HTTP/3：\(error.localizedDescription)") }
        try Task.checkCancellation()

        let quic: Availability<Double>
        switch await QUICProbe.handshake(host: host, port: port) {
        case .success(let ms): quic = .available(ms)
        case .failure(let e): quic = .unavailable(reason: "QUIC 交握失敗：\(e.localizedDescription)")
        }

        let tcpSamples = await LatencySampler.collect(probe: TCPConnectProbe(host: host, port: port), count: 5, interval: 0.2, timeout: 2)
        let tlsSamples = await LatencySampler.collect(probe: TCPConnectProbe(host: host, port: port, useTLS: true), count: 5, interval: 0.3, timeout: 3)
        try Task.checkCancellation()

        let httpProbe = HTTPLatencyProbe(url: url)
        var httpLatency: LatencyStatistics?
        do {
            try await httpProbe.prepare()
            httpLatency = LatencyStatistics.compute(from: await LatencySampler.collect(probe: httpProbe, count: 10, interval: 0.2, timeout: 3))
        } catch { errors.append("HTTP 延遲：\(error.localizedDescription)") }
        await httpProbe.close()

        func family(_ v: NWProtocolIP.Options.Version, _ name: String) async -> Availability<Double> {
            let samples = await LatencySampler.collect(probe: TCPConnectProbe(host: host, port: port, ipVersion: v), count: 3, interval: 0.2, timeout: 2)
            if let median = LatencyStatistics.compute(from: samples).rtt?.median { return .available(median) }
            return .unavailable(reason: "\(name) 無法連線")
        }
        let v4 = await family(.v4, "IPv4")
        let v6 = await family(.v6, "IPv6")

        return ProtocolProbeResult(date: Date(), host: host, http: http, http3Attempt: h3, quicHandshakeMs: quic,
                                   tcpConnect: LatencyStatistics.compute(from: tcpSamples), tlsConnect: LatencyStatistics.compute(from: tlsSamples),
                                   httpLatency: httpLatency, ipv4Reachable: v4, ipv6Reachable: v6, errors: errors)
    }
}
