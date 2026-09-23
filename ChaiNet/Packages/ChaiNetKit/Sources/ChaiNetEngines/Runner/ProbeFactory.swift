import Foundation
import Network
import ChaiNetCore

/// Creates latency probes for a server. Abstracted so tests can inject deterministic probes.
public protocol LatencyProbeFactory: Sendable {
    /// Round-trip probe for idle / loaded latency.
    func latencyProbe(for server: ServerDescriptor, ipPreference: IPFamilyPreference) -> any LatencyProbe
    /// Probe able to observe packet loss (UDP echo, else ICMP). `nil` when neither is possible.
    func lossProbe(for server: ServerDescriptor, payloadSize: Int, ipPreference: IPFamilyPreference) -> (probe: any LatencyProbe, method: String)?
}

public struct DefaultLatencyProbeFactory: LatencyProbeFactory {
    public init() {}

    static func version(_ p: IPFamilyPreference) -> NWProtocolIP.Options.Version? {
        switch p {
        case .automatic: nil
        case .ipv4Only: .v4
        case .ipv6Only: .v6
        }
    }

    public func latencyProbe(for server: ServerDescriptor, ipPreference: IPFamilyPreference) -> any LatencyProbe {
        // URLSession can't pin an IP family, so forced-family runs use TCP handshake timing.
        if let v = Self.version(ipPreference) {
            return TCPConnectProbe(host: server.host, port: UInt16(server.baseURL.port ?? 443), ipVersion: v)
        }
        return HTTPLatencyProbe(url: server.pingURL())
    }

    public func lossProbe(for server: ServerDescriptor, payloadSize: Int, ipPreference: IPFamilyPreference) -> (probe: any LatencyProbe, method: String)? {
        if let port = server.udpEchoPort {
            return (UDPEchoProbe(host: server.host, port: port, payloadSize: payloadSize, ipVersion: Self.version(ipPreference)),
                    "UDP echo → \(server.host):\(port)")
        }
        if ipPreference != .ipv6Only, let host = server.icmpHost ?? (SocketSupport.isIPv4Literal(server.host) ? server.host : nil) {
            return (ICMPEchoProbe(host: host, payloadSize: payloadSize), "ICMP echo → \(host)")
        }
        return nil
    }
}
