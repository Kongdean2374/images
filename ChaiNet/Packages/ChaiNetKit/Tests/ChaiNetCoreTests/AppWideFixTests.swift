import XCTest
@testable import ChaiNetCore

/// App-wide semantics fixes: QUIC vs HTTP/3, DNS tail, traceroute, interfaces, gaming path, IP redaction.
final class ProtocolEvidenceTests: XCTestCase {
    func http(_ proto: HTTPProtocolVersion) -> HTTPTimingBreakdown {
        HTTPTimingBreakdown(url: "https://x", dnsMs: 5, tcpConnectMs: 10, tlsMs: 20, ttfbMs: 60, totalMs: 70, negotiatedProtocol: proto,
                            reusedConnection: false, remoteAddress: nil, localAddress: nil, ipFamily: nil, tlsVersion: "1.3", statusCode: 200)
    }

    func probe(h3: Bool, quicOK: Bool) -> ProtocolProbeResult {
        var p = ProtocolProbeResult(date: Date(), host: "x", http: http(.http2), http3Attempt: http(h3 ? .http3 : .http2),
                                    quicHandshakeMs: quicOK ? .available(25) : .unavailable(reason: "timeout"),
                                    tcpConnect: nil, tlsConnect: nil, httpLatency: nil,
                                    ipv4Reachable: .available(10), ipv6Reachable: .available(12), errors: [])
        p.quicProbes = [QUICProbeOutcome(host: "cloudflare.com", handshakeMs: quicOK ? 25 : nil, failure: quicOK ? nil : .timeout, detail: nil, tcpReachable: true)]
        p.quicAssessment = QUICClassifier.classify(p.quicProbes!)
        return p
    }

    func codes(_ p: ProtocolProbeResult) -> Set<EvidenceCode> {
        var r = Fixture.result(.wifi)
        r.protocolProbe = p
        return Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
    }

    func testQUICHandshakeAloneIsNotHTTP3() {
        let p = probe(h3: false, quicOK: true)
        XCTAssertTrue(p.quicReachable)
        XCTAssertTrue(p.udp443Reachable)
        XCTAssertFalse(p.http3Negotiated)
        let c = codes(p)
        XCTAssertTrue(c.contains(.quicReachable))
        XCTAssertFalse(c.contains(.http3Negotiated), "only a real h3 response may produce http3Negotiated")
        var r = Fixture.result(.wifi)
        r.protocolProbe = p
        XCTAssertEqual(r.metrics.http3Supported, false)
        XCTAssertEqual(r.metrics.quicReachable, true)
    }

    func testNegotiatedHTTP3() {
        let c = codes(probe(h3: true, quicOK: true))
        XCTAssertTrue(c.contains(.http3Negotiated))
        XCTAssertTrue(c.contains(.quicReachable))
    }

    func testQUICReachableRulesOutUDPBlocking() {
        let analysis = RootCauseAnalyzer().analyze(evidence: EvidenceSet(
            evidence: [DiagnosticEvidence(code: .onWiFi, statement: "", interface: .wifi), DiagnosticEvidence(code: .quicReachable, statement: "")],
            measuredDimensions: Set(EvidenceDimension.allCases)))
        XCTAssertEqual(analysis.hypotheses.first { $0.cause == .udpQuicBlocked }?.likelihood, .ruledOut)
    }
}

final class DNSTailTests: XCTestCase {
    func testRule() {
        XCTAssertTrue(DNSTail.isHigh(median: 20, p95: 300))
        XCTAssertFalse(DNSTail.isHigh(median: 20, p95: 150), "below 200 ms absolute floor")
        XCTAssertFalse(DNSTail.isHigh(median: 120, p95: 250), "less than 3 × median")
    }

    func dnsResult(_ rtts: [Double]) -> TestResult {
        var r = Fixture.result(.wifi)
        let samples = rtts.enumerated().map { LatencySample(sequence: $0.offset, offset: Double($0.offset), rttMs: $0.element) }
        let system = DNSResolverResult(resolver: DNSResolverDescriptor(id: "system", name: "System", transport: .system, endpoint: ""),
                                       samples: samples, statistics: LatencyStatistics.compute(from: samples), errors: [])
        r.dns = DNSBenchmarkResult(date: Date(), domains: ["example.com"], resolvers: [system])
        return r
    }

    func testHealthyMedianWithSlowTail() {
        // 18 fast lookups, 2 very slow ones: median 15 ms, P95 ≈ 400 ms.
        let r = dnsResult(Array(repeating: 15, count: 18) + [420, 450])
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.dnsHighTailLatency))
        XCTAssertFalse(codes.contains(.dnsHealthy), "healthy must not be claimed with a high tail")
        XCTAssertFalse(codes.contains(.dnsSlow), "median is fine")
        XCTAssertTrue(DiagnosticsEngine().diagnose(r.metrics).contains { $0.code == .dnsHighTailLatency })
    }

    func testUniformlyFastIsHealthy() {
        let r = dnsResult(Array(repeating: 15, count: 20))
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.dnsHealthy))
        XCTAssertFalse(codes.contains(.dnsHighTailLatency))
    }
}

final class TracerouteAnalyzerTests: XCTestCase {
    func hop(_ ttl: Int, _ ms: Double?, dest: Bool = false) -> TracerouteHop {
        TracerouteHop(ttl: ttl, address: ms == nil ? nil : "10.0.0.\(ttl)", hostname: nil, rttsMs: [ms, ms, ms], reachedDestination: dest)
    }

    func testIsolatedHighHopIsNotCongestion() {
        let a = TracerouteAnalyzer.analyze([hop(1, 2), hop(2, 8), hop(3, 95), hop(4, 12), hop(5, 14, dest: true)])
        XCTAssertTrue(a.steps.isEmpty, "a later faster hop proves hop 3 just deprioritises ICMP")
        XCTAssertEqual(a.isolatedHighHops.map(\.ttl), [3])
    }

    func testPersistentStepIsDetected() {
        let a = TracerouteAnalyzer.analyze([hop(1, 2), hop(2, 8), hop(3, 10), hop(4, 60), hop(5, nil), hop(6, 62), hop(7, 63, dest: true)])
        XCTAssertEqual(a.steps.count, 1)
        XCTAssertEqual(a.largestStep?.fromTTL, 3)
        XCTAssertEqual(a.largestStep?.toTTL, 4)
        XCTAssertEqual(a.largestStep!.increaseMs, 50, accuracy: 0.01)
    }

    func testUnconfirmedLastHopIsNotAStep() {
        let a = TracerouteAnalyzer.analyze([hop(1, 2), hop(2, 8), hop(3, 90), hop(4, nil)])
        XCTAssertTrue(a.steps.isEmpty, "no later hop confirms the increase")
    }

    func testEvidence() {
        var r = Fixture.result(.wifi)
        r.traceroute = TracerouteResult(date: Date(), target: "t", resolvedAddress: "1.1.1.1",
                                        hops: [hop(1, 2), hop(2, 90), hop(3, 10), hop(4, 11, dest: true)], reachedDestination: true, method: "icmp")
        let (e, measured) = EvidenceExtractor().extract(test: SessionTest(label: "A", result: r))
        let codes = Set(e.map(\.code))
        XCTAssertTrue(codes.contains(.intermediateHopICMPDeprioritized))
        XCTAssertFalse(codes.contains(.routeLatencyStep))
        XCTAssertTrue(measured.contains(.route))
        XCTAssertEqual(EvidenceCode.intermediateHopICMPDeprioritized.kind, .heuristic)
    }
}

final class InterfaceDedupTests: XCTestCase {
    func testDeduplicatedKeepsOrder() {
        XCTAssertEqual(NetworkSnapshot.deduplicated([.cellular, .cellular, .other, .cellular, .wifi, .other]), [.cellular, .other, .wifi])
        var n = Fixture.network(.nr)
        n = NetworkSnapshot(capturedAt: n.capturedAt, status: n.status, primaryInterface: .cellular, availableInterfaces: [.cellular, .cellular, .cellular],
                            isExpensive: true, isConstrained: false, supportsIPv4: true, supportsIPv6: true, supportsDNS: true, localAddresses: [],
                            publicIPv4: n.publicIPv4, publicIPv6: n.publicIPv6, vpn: n.vpn, cellular: n.cellular, wifi: nil)
        XCTAssertEqual(n.availableInterfaces, [.cellular])
    }
}

final class GamingBestPathTests: XCTestCase {
    func candidate(_ name: String, median: Double, loss: Double = 0) -> GamingPathCandidate {
        GamingPathCandidate(name: name, host: name, method: "tcpConnect", statistics: Fixture.latency(median: median, lossPercent: loss), isPrimary: false)
    }

    func testBestHealthyPathDecides() {
        // Primary ICMP target slow (120 ms); a healthy regional path at 15 ms exists; a lossy 5 ms path is ignored.
        let primary = Fixture.latency(median: 120)
        let g = GamingQualityCalculator.evaluate(idle: primary, loaded: nil, spikes: [], packetsPerSecond: 50, downloadMbps: 100, score: nil,
                                                 alternatives: [candidate("regional", median: 15), candidate("lossy", median: 5, loss: 10)],
                                                 primaryName: "Cloudflare")
        XCTAssertEqual(g.referencePath, "regional (regional)")
        XCTAssertEqual(g.pathCandidates?.count, 3)
        XCTAssertEqual(g.verdicts.first { $0.genre == .competitiveShooter }?.verdict, .great)
        let single = GamingQualityCalculator.evaluate(idle: primary, loaded: nil, spikes: [], packetsPerSecond: 50, downloadMbps: 100, score: nil)
        XCTAssertGreaterThan(single.verdicts.first { $0.genre == .competitiveShooter }!.verdict, .great, "unchanged behaviour without alternatives")
    }

    func testLoadInflationCarriesOver() {
        let g = GamingQualityCalculator.evaluate(idle: Fixture.latency(median: 40), loaded: Fixture.latency(median: 340), spikes: [],
                                                 packetsPerSecond: 50, downloadMbps: 100, score: nil,
                                                 alternatives: [candidate("regional", median: 10)])
        XCTAssertGreaterThan(g.verdicts.first { $0.genre == .competitiveShooter }!.verdict, .playable, "bufferbloat still hurts on the best path")
    }
}

final class IPRedactionTests: XCTestCase {
    func testRedactsAllButWellKnownResolvers() {
        let text = "public_ipv4=203.0.113.9\nlocal=en0=192.168.1.5,utun3=fe80::1%utun3,pdp_ip0=10.64.2.1\npublic_ipv6=2001:db8:85a3::8a2e:370:7334\n"
            + "mapped=::ffff:100.64.0.1\nresolver=1.1.1.1 and 2606:4700:4700::1111\napp_version=2.1.0 (15)\nt=2026-09-23T12:30:45Z\nwindows=1.25,2.50"
        let out = IPRedactor.redact(text)
        for leaked in ["203.0.113.9", "192.168.1.5", "fe80::1", "10.64.2.1", "2001:db8:85a3", "100.64.0.1"] {
            XCTAssertFalse(out.contains(leaked), leaked)
        }
        XCTAssertTrue(out.contains("resolver=1.1.1.1 and 2606:4700:4700::1111"))
        XCTAssertTrue(out.contains("app_version=2.1.0 (15)"))
        XCTAssertTrue(out.contains("t=2026-09-23T12:30:45Z"))
        XCTAssertTrue(out.contains("windows=1.25,2.50"))
    }

    func testIPv6Validator() {
        XCTAssertTrue(IPRedactor.isIPv6("2001:db8::1"))
        XCTAssertTrue(IPRedactor.isIPv6("fe80::1%en0"))
        XCTAssertTrue(IPRedactor.isIPv6("1:2:3:4:5:6:7:8"))
        XCTAssertFalse(IPRedactor.isIPv6("12:30:45"))
        XCTAssertFalse(IPRedactor.isIPv6("aa:bb:cc:dd:ee:ff"))
        XCTAssertFalse(IPRedactor.isIPv6("1::2::3"))
    }

    func testExportDefaultsToAISafe() throws {
        var r = Fixture.result(.wifi)
        r.network.publicIPv4 = .available("203.0.113.9")
        let safe = RawDataExporter.text(r, analysis: nil, appVersion: "2.1.0", platform: "iOS")
        XCTAssertFalse(safe.contains("203.0.113.9"))
        XCTAssertTrue(safe.contains("public_ipv4=[REDACTED]"))
        XCTAssertTrue(safe.contains("export_privacy=aiSafe"))
        let json = String(decoding: try RawDataExporter.json(r, analysis: nil, appVersion: "2.1.0", platform: "iOS"), as: UTF8.self)
        XCTAssertFalse(json.contains("203.0.113.9"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)), "redacted JSON stays valid")
        let full = RawDataExporter.text(r, analysis: nil, appVersion: "2.1.0", platform: "iOS", privacy: .engineer(includeIPs: true))
        XCTAssertTrue(full.contains("public_ipv4=203.0.113.9"))
        let engineerDefault = RawDataExporter.text(r, analysis: nil, appVersion: "2.1.0", platform: "iOS", privacy: .engineer(includeIPs: false))
        XCTAssertFalse(engineerDefault.contains("203.0.113.9"))
    }
}
