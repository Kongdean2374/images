import Foundation
import ChaiNetCore

/// Deterministic engines for unit tests and SwiftUI previews. They never touch the network.
/// (Clearly separated from real engines — the app never ships mock data as measurements.)

public struct MockLatencyProbe: LatencyProbe {
    public var rtts: [Double?]
    public var delay: Double
    public var method: EndpointProbeMethod { .httpPing }
    public var targetDescription: String { "mock" }

    public init(rtts: [Double?], delay: Double = 0) {
        self.rtts = rtts
        self.delay = delay
    }

    public func prepare() async throws {}
    public func close() async {}
    public func probe(sequence: Int, timeout: Double) async -> Double? {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        guard !rtts.isEmpty else { return nil }
        return rtts[sequence % rtts.count]
    }
}

public struct MockProbeFactory: LatencyProbeFactory {
    public var latency: [Double?]
    public var loss: [Double?]?
    public init(latency: [Double?] = [20, 22, 21, 19], loss: [Double?]? = [20, 21, nil, 22]) {
        self.latency = latency
        self.loss = loss
    }
    public func latencyProbe(for server: ServerDescriptor, ipPreference: IPFamilyPreference) -> any LatencyProbe {
        MockLatencyProbe(rtts: latency)
    }
    public func lossProbe(for server: ServerDescriptor, payloadSize: Int, ipPreference: IPFamilyPreference) -> (probe: any LatencyProbe, method: String)? {
        loss.map { (MockLatencyProbe(rtts: $0), "mock") }
    }
}

/// Emits a constant-rate timeline quickly (`sampleDelay` between samples).
public struct MockSpeedTestEngine: SpeedTestEngineProtocol {
    public var mbps: Double
    public var sampleCount: Int
    public var sampleDelay: Double
    public init(mbps: Double = 100, sampleCount: Int = 30, sampleDelay: Double = 0) {
        self.mbps = mbps
        self.sampleCount = sampleCount
        self.sampleDelay = sampleDelay
    }

    public func run(_ configuration: SpeedTestConfiguration) -> AsyncThrowingStream<SpeedTestEvent, Error> {
        let mbps = mbps, count = sampleCount, delay = sampleDelay
        return makeCancellableStream { continuation in
            var samples: [SpeedSample] = []
            var cumulative: Int64 = 0
            continuation.yield(.streamsChanged(configuration.fixedStreams ?? 2))
            for i in 0..<count {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try Task.checkCancellation()
                let bytes = Int64(mbps * 1_000_000 / 8 * 0.1)
                cumulative += bytes
                let s = SpeedSample(offset: Double(i + 1) * 0.1, intervalDuration: 0.1, intervalBytes: bytes, cumulativeBytes: cumulative,
                                    activeStreams: configuration.fixedStreams ?? 2)
                samples.append(s)
                continuation.yield(.sample(s))
            }
            continuation.yield(.completed(SpeedResult(direction: configuration.direction, samples: samples,
                                                      summary: SpeedCalculator.summarize(samples: samples, warmupDuration: 0),
                                                      streamChanges: [StreamChange(offset: 0, streams: 2)], wasCancelled: false)))
        }
    }
}

public struct MockNetworkInfo: NetworkInfoProviding {
    public var snapshotValue: NetworkSnapshot
    public init(snapshot: NetworkSnapshot = MockNetworkInfo.wifi) {
        self.snapshotValue = snapshot
    }
    public func snapshot(includePublicIP: Bool) async -> NetworkSnapshot { snapshotValue }
    public func pathUpdates() -> AsyncStream<NetworkSnapshot> {
        let snap = snapshotValue
        return AsyncStream { continuation in continuation.yield(snap) }
    }

    public static let wifi = NetworkSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .satisfied, primaryInterface: .wifi, availableInterfaces: [.wifi, .cellular],
        isExpensive: false, isConstrained: false, supportsIPv4: true, supportsIPv6: true, supportsDNS: true,
        localAddresses: [InterfaceAddress(interfaceName: "en0", address: "192.168.1.20", family: .ipv4)],
        publicIPv4: .unavailable(reason: "預覽資料"), publicIPv6: .unavailable(reason: "預覽資料"),
        vpn: VPNDetection(state: .notDetected, interfaces: [], method: "預覽"), cellular: nil,
        wifi: WiFiInfo(ssid: .unavailable(reason: UnavailableReason.wifiSSID), bssid: .unavailable(reason: UnavailableReason.wifiSSID),
                       rssi: .unavailable(reason: UnavailableReason.wifiSignal)))
}

public struct MockServerDirectory: ServerDirectoryProtocol {
    public init() {}
    public func rank(_ servers: [ServerDescriptor]) async -> [ServerLatencyRanking] {
        servers.enumerated().map { ServerLatencyRanking(server: $0.element, medianMs: 10 + Double($0.offset), error: nil) }
    }
    public func info(for server: ServerDescriptor) async -> ServerInfo? { nil }
    public func health(for server: ServerDescriptor) async -> ServerHealth {
        ServerHealth(reachable: true, healthy: true, responseMs: 12, activeSessions: 1, detail: nil)
    }
}

public struct MockDNSEngine: DNSBenchmarkEngineProtocol {
    public init() {}
    public func run(resolvers: [DNSResolverDescriptor], domains: [String], progress: @escaping @Sendable (DNSResolverResult) -> Void) async throws -> DNSBenchmarkResult {
        let results = resolvers.enumerated().map { i, r -> DNSResolverResult in
            let samples = domains.enumerated().map { LatencySample(sequence: $0.offset, offset: 0, rttMs: 10 + Double(i * 5)) }
            return DNSResolverResult(resolver: r, samples: samples, statistics: LatencyStatistics.compute(from: samples), errors: [])
        }
        results.forEach(progress)
        return DNSBenchmarkResult(date: Date(), domains: domains, resolvers: results)
    }
}

public struct MockProtocolEngine: ProtocolProbeEngineProtocol {
    public init() {}
    public func run(url: URL) async throws -> ProtocolProbeResult {
        let t = HTTPTimingBreakdown(url: url.absoluteString, dnsMs: 5, tcpConnectMs: 12, tlsMs: 18, ttfbMs: 25, totalMs: 60,
                                    negotiatedProtocol: .http2, reusedConnection: false, remoteAddress: "203.0.113.1", localAddress: "192.168.1.20",
                                    ipFamily: .ipv4, tlsVersion: "TLS 1.3", statusCode: 200)
        return ProtocolProbeResult(date: Date(), host: url.host() ?? "", http: t, http3Attempt: t, quicHandshakeMs: .unavailable(reason: "mock"),
                                   tcpConnect: nil, tlsConnect: nil, httpLatency: nil, ipv4Reachable: .available(12), ipv6Reachable: .available(14), errors: [])
    }
}

public struct MockTracerouteEngine: TracerouteEngineProtocol {
    public init() {}
    public func run(host: String, maxHops: Int, probesPerHop: Int, onHop: @escaping @Sendable (TracerouteHop) -> Void) async throws -> TracerouteResult {
        let hops = (1...4).map { TracerouteHop(ttl: $0, address: "10.0.0.\($0)", hostname: nil, rttsMs: [Double($0 * 3)], reachedDestination: $0 == 4) }
        hops.forEach(onHop)
        return TracerouteResult(date: Date(), target: host, resolvedAddress: "10.0.0.4", hops: hops, reachedDestination: true, method: "mock")
    }
}

public struct MockMTUEngine: MTUDiscoveryEngineProtocol {
    public init() {}
    public func run(host: String) async throws -> MTUResult {
        MTUResult(date: Date(), target: host, pathMTU: 1500, probes: [], method: "mock")
    }
}

public struct MockCrossValidationEngine: CrossValidationEngineProtocol {
    public init() {}
    public func run(endpoints: [ValidationEndpoint], probes: Int) async -> [EndpointCheck] {
        endpoints.map { e in
            let samples = (0..<probes).map { LatencySample(sequence: $0, offset: 0, rttMs: 15) }
            return EndpointCheck(id: e.id, name: e.name, host: e.host, region: e.region, method: .icmpEcho,
                                 statistics: LatencyStatistics.compute(from: samples), error: nil, isPrimary: false)
        }
    }
}

public struct MockIPFamilyEngine: IPFamilyCompareEngineProtocol {
    public init() {}
    public func run(host: String, port: UInt16, probes: Int) async -> IPFamilyComparisonResult {
        let s = LatencyStatistics.compute(from: (0..<probes).map { LatencySample(sequence: $0, offset: 0, rttMs: 15) })
        return IPFamilyComparisonResult(target: host, method: .tcpConnect, ipv4: s, ipv6: s, ipv4Error: nil, ipv6Error: nil)
    }
}

public struct MockInterfaceEngine: InterfaceCompareEngineProtocol {
    public init() {}
    public func run(host: String, interfaces: [InterfaceKind], probes: Int) async -> [InterfaceProbeResult] {
        interfaces.map { InterfaceProbeResult(interface: $0, tcpConnect: nil, error: "mock") }
    }
}

public extension TestRunner {
    /// Fully mocked runner: fast, offline, deterministic.
    static func mock(downloadMbps: Double = 300, sampleDelay: Double = 0.01) -> TestRunner {
        TestRunner(speed: MockSpeedTestEngine(mbps: downloadMbps, sampleDelay: sampleDelay), dns: MockDNSEngine(), protocols: MockProtocolEngine(),
                   traceroute: MockTracerouteEngine(), mtu: MockMTUEngine(), crossValidation: MockCrossValidationEngine(),
                   ipFamilies: MockIPFamilyEngine(), interfaces: MockInterfaceEngine(), servers: MockServerDirectory(),
                   networkInfo: MockNetworkInfo(), probes: MockProbeFactory(),
                   ndt7: MockSpeedTestEngine(mbps: downloadMbps / 2, sampleDelay: sampleDelay), stressProbes: MockStressProbeFactory())
    }
}
