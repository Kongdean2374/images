import Foundation

/// Flat set of metrics consumed by the Score and Diagnostics engines.
///
/// Every field is optional: engines only use what was measured and never substitute defaults
/// for missing data.
public struct MetricSnapshot: Codable, Sendable, Hashable {
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    public var downloadPeakMbps: Double?
    public var downloadStability: Double?
    public var uploadStability: Double?
    public var idleLatencyMs: Double?
    public var idleLatencyP95Ms: Double?
    public var jitterMs: Double?
    public var lossPercent: Double?
    public var lossPattern: LossPattern?
    public var burstLossPercent: Double?
    public var downloadBloatMs: Double?
    public var uploadBloatMs: Double?
    public var systemDNSMs: Double?
    public var systemDNSP95Ms: Double?
    public var bestDNSMs: Double?
    public var bestDNSName: String?
    public var supportsIPv4: Bool?
    public var supportsIPv6: Bool?
    public var vpnDetected: Bool?
    public var isExpensive: Bool?
    public var isConstrained: Bool?
    public var interface: InterfaceKind?
    public var negotiatedHTTP: HTTPProtocolVersion?
    /// HTTP/3 actually negotiated (not merely a QUIC handshake).
    public var http3Supported: Bool?
    /// QUIC handshake / UDP 443 reachable.
    public var quicReachable: Bool?
    /// Host the HTTP / HTTP-3 probe targeted (findings are scoped to it).
    public var http3ProbeHost: String?
    public var tlsHandshakeMs: Double?
    public var ttfbMs: Double?
    public var pathMTU: Int?
    public var spikeCount: Int?
    public var dropCount: Int?
    public var sampleDurationSeconds: Double?

    public init() {}
}
