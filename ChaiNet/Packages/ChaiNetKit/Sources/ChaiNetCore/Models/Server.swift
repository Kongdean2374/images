import Foundation

/// How a server exposes its measurement endpoints.
public enum ServerKind: String, Codable, Sendable, Hashable {
    /// The ChaiNet Go backend (`/ping`, `/download`, `/upload`, `/health`, `/info`, UDP echo).
    case chainet
    /// Cloudflare's public speed endpoints (`speed.cloudflare.com/__down`, `/__up`). Used as an
    /// out-of-the-box fallback; no UDP echo, so packet loss falls back to ICMP.
    case cloudflare
}

public struct ServerDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var location: String
    public var kind: ServerKind
    public var baseURL: URL
    /// UDP echo port for loss / jitter / gaming tests (ChaiNet backend only).
    public var udpEchoPort: UInt16?
    /// Host used for ICMP-based tools when UDP echo is not available.
    public var icmpHost: String?
    public var isCustom: Bool

    public init(id: String, name: String, location: String, kind: ServerKind, baseURL: URL,
                udpEchoPort: UInt16? = nil, icmpHost: String? = nil, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.location = location
        self.kind = kind
        self.baseURL = baseURL
        self.udpEchoPort = udpEchoPort
        self.icmpHost = icmpHost
        self.isCustom = isCustom
    }

    public var host: String { baseURL.host() ?? baseURL.absoluteString }

    public func pingURL() -> URL {
        switch kind {
        case .chainet: baseURL.appending(path: "ping")
        case .cloudflare: Self.withQuery(baseURL.appending(path: "__down"), [URLQueryItem(name: "bytes", value: "0")])
        }
    }

    public func downloadURL(bytes: Int) -> URL {
        switch kind {
        case .chainet: Self.withQuery(baseURL.appending(path: "download"), [URLQueryItem(name: "bytes", value: String(bytes))])
        case .cloudflare: Self.withQuery(baseURL.appending(path: "__down"), [URLQueryItem(name: "bytes", value: String(bytes))])
        }
    }

    public func uploadURL() -> URL {
        switch kind {
        case .chainet: baseURL.appending(path: "upload")
        case .cloudflare: baseURL.appending(path: "__up")
        }
    }

    public func infoURL() -> URL? {
        kind == .chainet ? baseURL.appending(path: "info") : nil
    }

    public func healthURL() -> URL? {
        kind == .chainet ? baseURL.appending(path: "health") : nil
    }

    private static func withQuery(_ url: URL, _ items: [URLQueryItem]) -> URL {
        url.appending(queryItems: items)
    }

    /// Built-in servers. Replace / extend with your own ChaiNet backend deployments in Settings.
    public static let builtIn: [ServerDescriptor] = [
        ServerDescriptor(id: "cloudflare", name: "Cloudflare（公用）", location: "Anycast 全球節點", kind: .cloudflare,
                         baseURL: URL(string: "https://speed.cloudflare.com")!, udpEchoPort: nil, icmpHost: "1.1.1.1"),
    ]
}

/// Response of the backend `/info` endpoint.
public struct ServerInfo: Codable, Sendable, Hashable {
    public var name: String
    public var location: String
    public var version: String
    public var clientIP: String
    public var clientIPFamily: String
    public var httpProtocol: String
    public var supportsHTTP3: Bool
    public var udpEchoPort: UInt16?
    public var maxDownloadBytes: Int64
    public var maxUploadBytes: Int64
    public var maxTestDurationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case name, location, version
        case clientIP = "client_ip"
        case clientIPFamily = "client_ip_family"
        case httpProtocol = "http_protocol"
        case supportsHTTP3 = "supports_http3"
        case udpEchoPort = "udp_echo_port"
        case maxDownloadBytes = "max_download_bytes"
        case maxUploadBytes = "max_upload_bytes"
        case maxTestDurationSeconds = "max_test_duration_seconds"
    }
}

/// Latency ranking produced by server selection.
public struct ServerLatencyRanking: Codable, Sendable, Hashable, Identifiable {
    public var server: ServerDescriptor
    public var medianMs: Double?
    public var error: String?
    public var id: String { server.id }

    public init(server: ServerDescriptor, medianMs: Double?, error: String?) {
        self.server = server
        self.medianMs = medianMs
        self.error = error
    }
}
