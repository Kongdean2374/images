import Foundation

// MARK: - DNS

public enum DNSTransport: String, Codable, Sendable, Hashable {
    /// The OS resolver (getaddrinfo) — what apps actually use.
    case system
    /// Plain DNS over UDP port 53 to a specific resolver.
    case udp
    /// DNS-over-HTTPS (RFC 8484).
    case doh
}

public struct DNSResolverDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var transport: DNSTransport
    /// IP for UDP, URL string for DoH, empty for system.
    public var endpoint: String

    public init(id: String, name: String, transport: DNSTransport, endpoint: String) {
        self.id = id
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
    }

    public static let defaults: [DNSResolverDescriptor] = [
        DNSResolverDescriptor(id: "system", name: "系統預設", transport: .system, endpoint: ""),
        DNSResolverDescriptor(id: "cf-udp", name: "Cloudflare 1.1.1.1", transport: .udp, endpoint: "1.1.1.1"),
        DNSResolverDescriptor(id: "google-udp", name: "Google 8.8.8.8", transport: .udp, endpoint: "8.8.8.8"),
        DNSResolverDescriptor(id: "quad9-udp", name: "Quad9 9.9.9.9", transport: .udp, endpoint: "9.9.9.9"),
        DNSResolverDescriptor(id: "cf-v6", name: "Cloudflare IPv6", transport: .udp, endpoint: "2606:4700:4700::1111"),
        DNSResolverDescriptor(id: "cf-doh", name: "Cloudflare DoH", transport: .doh, endpoint: "https://cloudflare-dns.com/dns-query"),
        DNSResolverDescriptor(id: "google-doh", name: "Google DoH", transport: .doh, endpoint: "https://dns.google/dns-query"),
    ]
}

public struct DNSResolverResult: Codable, Sendable, Hashable, Identifiable {
    public var resolver: DNSResolverDescriptor
    /// Lookup times, nil = failed / timed out, in query order.
    public var samples: [LatencySample]
    public var statistics: LatencyStatistics
    public var errors: [String]
    public var id: String { resolver.id }

    public init(resolver: DNSResolverDescriptor, samples: [LatencySample], statistics: LatencyStatistics, errors: [String]) {
        self.resolver = resolver
        self.samples = samples
        self.statistics = statistics
        self.errors = errors
    }
}

public struct DNSBenchmarkResult: Codable, Sendable, Hashable {
    public var date: Date
    public var domains: [String]
    public var resolvers: [DNSResolverResult]

    public init(date: Date, domains: [String], resolvers: [DNSResolverResult]) {
        self.date = date
        self.domains = domains
        self.resolvers = resolvers
    }

    /// Resolvers ordered by median lookup time; failed resolvers last.
    public var ranked: [DNSResolverResult] {
        resolvers.sorted { ($0.statistics.rtt?.median ?? .infinity) < ($1.statistics.rtt?.median ?? .infinity) }
    }
}

// MARK: - HTTP / TCP / TLS / QUIC

public enum HTTPProtocolVersion: String, Codable, Sendable, Hashable {
    case http1_0 = "http/1.0"
    case http1_1 = "http/1.1"
    case http2 = "h2"
    case http3 = "h3"
    case unknown

    /// Maps `URLSessionTaskTransactionMetrics.networkProtocolName`.
    public init(alpn: String?) {
        switch alpn?.lowercased() {
        case "http/1.0": self = .http1_0
        case "http/1.1": self = .http1_1
        case "h2", "h2c": self = .http2
        case let s? where s.hasPrefix("h3"): self = .http3
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .http1_0: "HTTP/1.0"
        case .http1_1: "HTTP/1.1"
        case .http2: "HTTP/2"
        case .http3: "HTTP/3 (QUIC)"
        case .unknown: "未知"
        }
    }
}

/// Timing breakdown of one HTTP request (from `URLSessionTaskMetrics`).
public struct HTTPTimingBreakdown: Codable, Sendable, Hashable {
    public var url: String
    public var dnsMs: Double?
    /// TCP connect (for QUIC: nil, handshake is reported in `tlsMs`).
    public var tcpConnectMs: Double?
    /// TLS handshake (or QUIC crypto handshake).
    public var tlsMs: Double?
    /// Request start → first response byte.
    public var ttfbMs: Double?
    /// Fetch start → response end.
    public var totalMs: Double?
    public var negotiatedProtocol: HTTPProtocolVersion
    public var reusedConnection: Bool
    public var remoteAddress: String?
    public var localAddress: String?
    public var ipFamily: InterfaceAddress.Family?
    public var tlsVersion: String?
    public var statusCode: Int?

    public init(url: String, dnsMs: Double?, tcpConnectMs: Double?, tlsMs: Double?, ttfbMs: Double?, totalMs: Double?,
                negotiatedProtocol: HTTPProtocolVersion, reusedConnection: Bool, remoteAddress: String?, localAddress: String?,
                ipFamily: InterfaceAddress.Family?, tlsVersion: String?, statusCode: Int?) {
        self.url = url
        self.dnsMs = dnsMs
        self.tcpConnectMs = tcpConnectMs
        self.tlsMs = tlsMs
        self.ttfbMs = ttfbMs
        self.totalMs = totalMs
        self.negotiatedProtocol = negotiatedProtocol
        self.reusedConnection = reusedConnection
        self.remoteAddress = remoteAddress
        self.localAddress = localAddress
        self.ipFamily = ipFamily
        self.tlsVersion = tlsVersion
        self.statusCode = statusCode
    }
}

public struct ProtocolProbeResult: Codable, Sendable, Hashable {
    public var date: Date
    public var host: String
    /// Fresh-connection HTTP request (default negotiation, usually h2).
    public var http: HTTPTimingBreakdown?
    /// Request with `assumesHTTP3Capable` — tells whether HTTP/3 was negotiated.
    public var http3Attempt: HTTPTimingBreakdown?
    /// Raw QUIC handshake time via Network.framework (ALPN h3).
    public var quicHandshakeMs: Availability<Double>
    /// TCP connect time via Network.framework.
    public var tcpConnect: LatencyStatistics?
    /// Time-to-ready of a TLS connection via Network.framework (TCP + TLS).
    public var tlsConnect: LatencyStatistics?
    /// Repeated HTTP latency on a warm connection.
    public var httpLatency: LatencyStatistics?
    public var ipv4Reachable: Availability<Double>
    public var ipv6Reachable: Availability<Double>
    public var errors: [String]

    public init(date: Date, host: String, http: HTTPTimingBreakdown?, http3Attempt: HTTPTimingBreakdown?,
                quicHandshakeMs: Availability<Double>, tcpConnect: LatencyStatistics?, tlsConnect: LatencyStatistics?,
                httpLatency: LatencyStatistics?, ipv4Reachable: Availability<Double>, ipv6Reachable: Availability<Double>, errors: [String]) {
        self.date = date
        self.host = host
        self.http = http
        self.http3Attempt = http3Attempt
        self.quicHandshakeMs = quicHandshakeMs
        self.tcpConnect = tcpConnect
        self.tlsConnect = tlsConnect
        self.httpLatency = httpLatency
        self.ipv4Reachable = ipv4Reachable
        self.ipv6Reachable = ipv6Reachable
        self.errors = errors
    }

    public var http3Supported: Bool { http3Attempt?.negotiatedProtocol == .http3 || quicHandshakeMs.value != nil }
}

// MARK: - Route

public struct TracerouteHop: Codable, Sendable, Hashable, Identifiable {
    public var ttl: Int
    /// Responding router address; nil if every probe timed out ("*").
    public var address: String?
    public var hostname: String?
    /// RTT per probe; nil = no reply.
    public var rttsMs: [Double?]
    /// True when this hop is the destination (echo reply received).
    public var reachedDestination: Bool
    public var id: Int { ttl }

    public init(ttl: Int, address: String?, hostname: String?, rttsMs: [Double?], reachedDestination: Bool) {
        self.ttl = ttl
        self.address = address
        self.hostname = hostname
        self.rttsMs = rttsMs
        self.reachedDestination = reachedDestination
    }

    public var bestMs: Double? { rttsMs.compactMap { $0 }.min() }
    public var lossPercent: Double {
        guard !rttsMs.isEmpty else { return 0 }
        return Double(rttsMs.filter { $0 == nil }.count) / Double(rttsMs.count) * 100
    }
}

public struct TracerouteResult: Codable, Sendable, Hashable {
    public var date: Date
    public var target: String
    public var resolvedAddress: String
    public var hops: [TracerouteHop]
    public var reachedDestination: Bool
    public var method: String

    public init(date: Date, target: String, resolvedAddress: String, hops: [TracerouteHop], reachedDestination: Bool, method: String) {
        self.date = date
        self.target = target
        self.resolvedAddress = resolvedAddress
        self.hops = hops
        self.reachedDestination = reachedDestination
        self.method = method
    }
}

public struct MTUProbe: Codable, Sendable, Hashable {
    /// IP packet size in bytes (IP header + ICMP header + payload).
    public var packetSize: Int
    public var succeeded: Bool
    public var note: String?

    public init(packetSize: Int, succeeded: Bool, note: String?) {
        self.packetSize = packetSize
        self.succeeded = succeeded
        self.note = note
    }
}

public struct MTUResult: Codable, Sendable, Hashable {
    public var date: Date
    public var target: String
    /// Largest packet that passed with DF set. nil when even the minimum failed.
    public var pathMTU: Int?
    public var probes: [MTUProbe]
    public var method: String

    public init(date: Date, target: String, pathMTU: Int?, probes: [MTUProbe], method: String) {
        self.date = date
        self.target = target
        self.pathMTU = pathMTU
        self.probes = probes
        self.method = method
    }
}
