import Foundation
import Network
import ChaiNetCore

/// An independent endpoint used for cross-validation.
public struct ValidationEndpoint: Sendable, Hashable {
    public var id: String
    public var name: String
    public var host: String
    public var region: String

    public init(id: String, name: String, host: String, region: String) {
        self.id = id
        self.name = name
        self.host = host
        self.region = region
    }

    /// Independent anycast networks (different operators → independent paths).
    public static let defaults: [ValidationEndpoint] = [
        ValidationEndpoint(id: "cf-1.1.1.1", name: "Cloudflare 1.1.1.1", host: "1.1.1.1", region: "Anycast · Cloudflare"),
        ValidationEndpoint(id: "google-8.8.8.8", name: "Google 8.8.8.8", host: "8.8.8.8", region: "Anycast · Google"),
        ValidationEndpoint(id: "quad9-9.9.9.9", name: "Quad9 9.9.9.9", host: "9.9.9.9", region: "Anycast · Quad9"),
        ValidationEndpoint(id: "apple", name: "Apple", host: "www.apple.com", region: "CDN · Apple"),
    ]
}

public protocol CrossValidationEngineProtocol: Sendable {
    func run(endpoints: [ValidationEndpoint], probes: Int) async -> [EndpointCheck]
}

/// Measures several independent endpoints so a problem can be localised
/// (one server vs. every destination). Uses ICMP echo (sees real loss) and falls back to TCP
/// connect with a 1 s timeout (a lost SYN appears as a timeout) when ICMP is unavailable.
public struct CrossValidationEngine: CrossValidationEngineProtocol {
    public init() {}

    public func run(endpoints: [ValidationEndpoint], probes: Int = 30) async -> [EndpointCheck] {
        await withTaskGroup(of: EndpointCheck.self) { group in
            for endpoint in endpoints {
                group.addTask { await Self.check(endpoint, probes: probes) }
            }
            var out: [EndpointCheck] = []
            for await c in group { out.append(c) }
            return out.sorted { $0.name < $1.name }
        }
    }

    static func check(_ e: ValidationEndpoint, probes: Int) async -> EndpointCheck {
        let icmp = ICMPEchoProbe(host: e.host)
        do {
            try await icmp.prepare()
            let samples = await LatencySampler.collect(probe: icmp, count: probes, interval: 0.1, timeout: 1.5)
            await icmp.close()
            let stats = LatencyStatistics.compute(from: samples)
            // ICMP completely filtered → retry with TCP rather than reporting 100 % loss.
            if stats.rtt != nil {
                return EndpointCheck(id: e.id, name: e.name, host: e.host, region: e.region, method: .icmpEcho, statistics: stats, error: nil, isPrimary: false)
            }
        } catch {
            await icmp.close()
        }
        let tcp = TCPConnectProbe(host: e.host, port: 443)
        let samples = await LatencySampler.collect(probe: tcp, count: min(probes, 15), interval: 0.2, timeout: 1.0)
        let stats = LatencyStatistics.compute(from: samples)
        return EndpointCheck(id: e.id, name: e.name, host: e.host, region: e.region, method: .tcpConnect, statistics: stats,
                             error: stats.rtt == nil ? "無回應" : nil, isPrimary: false)
    }
}

public protocol IPFamilyCompareEngineProtocol: Sendable {
    func run(host: String, port: UInt16, probes: Int) async -> IPFamilyComparisonResult
}

/// Measures the same host over IPv4 and IPv6 separately (Network.framework IP version pinning).
public struct IPFamilyCompareEngine: IPFamilyCompareEngineProtocol {
    public init() {}

    public func run(host: String, port: UInt16 = 443, probes: Int = 15) async -> IPFamilyComparisonResult {
        async let v4 = LatencySampler.collect(probe: TCPConnectProbe(host: host, port: port, ipVersion: .v4), count: probes, interval: 0.2, timeout: 1.5)
        async let v6 = LatencySampler.collect(probe: TCPConnectProbe(host: host, port: port, ipVersion: .v6), count: probes, interval: 0.2, timeout: 1.5)
        let s4 = LatencyStatistics.compute(from: await v4)
        let s6 = LatencyStatistics.compute(from: await v6)
        return IPFamilyComparisonResult(target: "\(host):\(port)", method: .tcpConnect,
                                        ipv4: s4.rtt == nil ? nil : s4, ipv6: s6.rtt == nil ? nil : s6,
                                        ipv4Error: s4.rtt == nil ? "IPv4 無法連線" : nil, ipv6Error: s6.rtt == nil ? "IPv6 無法連線" : nil)
    }
}

public protocol InterfaceCompareEngineProtocol: Sendable {
    func run(host: String, interfaces: [InterfaceKind], probes: Int) async -> [InterfaceProbeResult]
}

/// Latency over specific interfaces *simultaneously* (e.g. cellular while connected to Wi-Fi)
/// using `NWParameters.requiredInterfaceType`.
///
/// Limitation: iOS cannot force LTE vs 5G; that comparison needs the user to switch in Settings.
/// URLSession can't be pinned to an interface, so only latency (not throughput) is compared here.
public struct InterfaceCompareEngine: InterfaceCompareEngineProtocol {
    public init() {}

    public func run(host: String, interfaces: [InterfaceKind] = [.wifi, .cellular], probes: Int = 15) async -> [InterfaceProbeResult] {
        var out: [InterfaceProbeResult] = []
        for kind in interfaces {
            guard let type = NWAsync.interfaceType(kind) else { continue }
            let samples = await LatencySampler.collect(probe: TCPConnectProbe(host: host, interface: type), count: probes, interval: 0.2, timeout: 2)
            let stats = LatencyStatistics.compute(from: samples)
            out.append(InterfaceProbeResult(interface: kind, tcpConnect: stats.rtt == nil ? nil : stats,
                                            error: stats.rtt == nil ? "\(kind.displayName) 無法使用或未連線" : nil))
        }
        return out
    }
}
