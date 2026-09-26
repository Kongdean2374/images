import XCTest
@testable import ChaiNetCore

/// Fixtures from the v2.1.2 raw export: conclusions must stay scoped to what was measured.
final class ScientificRigorTests: XCTestCase {
    static func samples(_ rtts: [Double?], step: Double = 0.2) -> [LatencySample] {
        rtts.enumerated().map { LatencySample(sequence: $0.offset, offset: Double($0.offset) * step, rttMs: $0.element) }
    }

    static func lossProbe(_ id: String, target: String, lost: Int, of count: Int, stress: Bool = false) -> LossProbeResult {
        LossProbeResult(id: id, name: id, target: target, method: "icmpEcho", packetsPerSecond: stress ? 50 : 5, isStressProbe: stress,
                        samples: samples((0..<count).map { $0 < lost ? nil : 20 }))
    }

    // MARK: Loss — Cloudflare lost, Google / Quad9 clean ≠ noLoss

    func testEndpointSpecificLossIsNotNoLoss() {
        let stress = Self.lossProbe("stress", target: "1.1.1.1", lost: 14, of: 1500, stress: true)
        let controls = [Self.lossProbe("cf", target: "1.1.1.1", lost: 1, of: 150),
                        Self.lossProbe("google", target: "8.8.8.8", lost: 0, of: 150),
                        Self.lossProbe("quad9", target: "9.9.9.9", lost: 0, of: 150)]
        let c = LossConfirmation.evaluate(stress: stress, controls: controls)
        XCTAssertEqual(c.verdict, .endpointSpecificLossObserved)
        XCTAssertNotEqual(c.verdict, .noLoss)
        XCTAssertNotEqual(c.verdict, .noConfirmedGeneralPacketLoss)
        XCTAssertEqual(c.affectedTargets, ["1.1.1.1"])
        XCTAssertEqual(c.cleanTargets, ["8.8.8.8", "9.9.9.9"])

        let nodes = [StressNode.throughputNode(for: ServerDescriptor.builtIn[0])] + StressNode.latencyOnlyDefaults
        let s = StressSummary(plan: StressTestPlan.make(totalSeconds: 300, nodes: nodes), configuredSeconds: 300, actualSeconds: 300, nodes: nodes,
                              transfers: [], phases: [], stressProbe: stress, controlProbes: controls,
                              preLoadLatency: Fixture.latency(median: 20), preLoadSamples: nil, postLoadLatency: [], postLoadSamples: [], warnings: [])
        var r = Fixture.result(.wifi)
        r.kind = .extremeStressTest
        r.stress = s
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.endpointSpecificLossObserved))
        XCTAssertFalse(codes.contains(.lossNone))
        XCTAssertFalse(codes.contains(.lossHigh))
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.0", platform: "iOS")
        XCTAssertTrue(text.contains("loss_verdict=endpointSpecificLossObserved"))
        XCTAssertTrue(text.contains("affected_targets=1.1.1.1"))
        XCTAssertTrue(text.contains("clean_targets=8.8.8.8,9.9.9.9"))
    }

    // MARK: Throughput — mixed methods are never "consistent"

    func testMixedMethodsAreNotConsistent() {
        let v = [ServerThroughputValue(nodeID: "cloudflare", name: "Cloudflare", provider: .cloudflare, mbps: 300, method: "HTTP x16"),
                 ServerThroughputValue(nodeID: "mlab-ndt7", name: "M-Lab", provider: .mlab, mbps: 295, method: "NDT7 WebSocket x1")]
        let a = CrossProviderAggregate.make(.download, values: v)!
        XCTAssertEqual(a.methodEquivalent, false)
        XCTAssertFalse(a.isConsistent, "almost equal numbers from different methods are not a consistency claim")
        XCTAssertFalse(a.comparable)
        XCTAssertEqual(v[0].streamCount, 16)
        XCTAssertEqual(v[1].streamCount, 1)
        XCTAssertEqual(v[1].transportProtocol, "WebSocket/TCP (NDT7)")

        let t = StressValidityTests.self
        let s = t.summary([t.transfer("cloudflare", round: 1, .download, t.speed(.download, mbps: 300, seconds: 20), loadedMs: 40),
                           t.transfer("mlab-ndt7", round: 1, .download, t.speed(.download, mbps: 120, seconds: 10), loadedMs: 40)])
        XCTAssertEqual(s.downloadAggregate?.methodEquivalent, false)
        XCTAssertEqual(s.headlineScope(.download), "primary_method")
        XCTAssertEqual(s.headlineMbps(.download)!, 300, accuracy: 2, "headline = primary HTTP test, NDT7 not averaged in")
        var r = Fixture.result(.wifi)
        r.kind = .extremeStressTest
        r.stress = s
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertFalse(codes.contains(.crossProviderThroughputConsistent))
        XCTAssertFalse(codes.contains(.largeCrossProviderThroughputVariance))
        XCTAssertTrue(codes.contains(.methodDependentThroughputDifference) || codes.contains(.crossProviderObservedRange))
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.0", platform: "iOS")
        XCTAssertTrue(text.contains("comparison_method_equivalent=false"))
        XCTAssertTrue(text.contains("coefficient_of_variation=not_comparable"))
        XCTAssertTrue(text.contains("headline_scope=primary_method"))
        XCTAssertTrue(text.contains("mlab-ndt7,validation,NDT7 WebSocket x1,1,WebSocket/TCP (NDT7)"))
    }

    // MARK: IPv6 — TCP fine, IPv6 DNS over UDP failing

    func testIPv6TCPOkButIPv6DNSFailingIsNotRuledOut() {
        let ev = [DiagnosticEvidence(code: .onWiFi, statement: "", interface: .wifi),
                  DiagnosticEvidence(code: .ipFamiliesEquivalent, statement: ""),
                  DiagnosticEvidence(code: .alternateIPv6ResolverDegraded, statement: "")]
        let a = RootCauseAnalyzer().analyze(evidence: EvidenceSet(evidence: ev, measuredDimensions: Set(EvidenceDimension.allCases)))
        let routing = a.hypotheses.first { $0.cause == .ipv6RoutingIssue }!
        XCTAssertNotEqual(routing.likelihood, .ruledOut)
        XCTAssertEqual(routing.likelihood, .broadIssueUnlikely)
        XCTAssertEqual(a.hypotheses.first { $0.cause == .ipv6SpecificPathIssue }?.likelihood, .possible)
    }

    func testDNSAnalyzerClassification() {
        func resolver(_ id: String, _ transport: DNSTransport, _ endpoint: String, _ rtts: [Double?]) -> DNSResolverResult {
            let s = Self.samples(rtts, step: 1)
            return DNSResolverResult(resolver: DNSResolverDescriptor(id: id, name: id, transport: transport, endpoint: endpoint),
                                     samples: s, statistics: LatencyStatistics.compute(from: s), errors: [])
        }
        // Domain #3 ("slow.example") is slow on every resolver: a cold authoritative lookup.
        let domains = ["a.example", "b.example", "c.example", "slow.example", "d.example", "e.example"]
        let dns = DNSBenchmarkResult(date: Date(), domains: domains, resolvers: [
            resolver("system", .system, "", [15, 16, 15, 400, 16, 15]),
            resolver("cloudflare-v4", .udp, "1.1.1.1", [12, 13, 12, 380, 12, 13]),
            resolver("cloudflare-v6", .udp, "2606:4700:4700::1111", [nil, nil, 30, nil, 31, nil]),
            resolver("google-doh", .doh, "https://dns.google/dns-query", [25, 26, 25, 420, 24, 25]),
        ])
        XCTAssertEqual(DNSAnalyzer.outlierDomains(dns), ["slow.example"])
        let findings = DNSAnalyzer.analyze(dns)
        XCTAssertTrue(findings.contains { $0.kind == .domainSpecificOutlier && $0.subject == "slow.example" })
        XCTAssertTrue(findings.contains { $0.kind == .ipv6DNSPathIssue && $0.subject == "cloudflare-v6" })
        XCTAssertTrue(findings.contains { $0.kind == .resolverWideDegradation && $0.subject == "cloudflare-v6" })
        XCTAssertFalse(findings.contains { $0.kind == .resolverWideDegradation && $0.subject == "system" }, "one cold domain is not resolver-wide")
        let rows = DNSAnalyzer.rows(dns)
        XCTAssertEqual(rows.count, 24)
        XCTAssertEqual(rows.first { $0.resolverID == "cloudflare-v6" && $0.domain == "a.example" }?.status, "fail")
        XCTAssertTrue(rows.allSatisfy { $0.cached == "unknown" })
        // The system tail disappears once the cold domain is excluded.
        XCTAssertLessThan(DNSAnalyzer.systemStatsExcludingOutliers(dns)!.rtt!.p95, 20)

        var r = Fixture.result(.wifi)
        r.dns = dns
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.0", platform: "iOS")
        XCTAssertTrue(text.contains("[dns_lookups]"))
        XCTAssertTrue(text.contains("domain,transport,resolver,latency_ms,status,cached_or_unknown"))
        XCTAssertTrue(text.contains("slow.example,system,system,400.00,ok,unknown"))
        XCTAssertTrue(text.contains("dns_finding=domainSpecificOutlier subject=slow.example"))
    }

    // MARK: Spikes — the 324 ms outlier is not "spikes=0"

    func testEarly324msOutlierIsASpike() {
        let series: [Double?] = [55, 324, 52, 58, 60, 54, 57, 53, 56, 59, 61, 55, 58, 54, 60, 57, 56, 55, 53, 58]
        let s = SpikeAnalyzer.analyze(Self.samples(series))!
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.worstMs, 324)
        XCTAssertEqual(s.offsets.count, 1)
        XCTAssertEqual(s.offsets[0], 0.2, accuracy: 1e-9)
        XCTAssertEqual(s.baselineSource, "series")
        XCTAssertEqual(s.thresholdMs, max(s.baselineMedianMs + 50, s.baselineP95Ms + 50, s.baselineMedianMs * 2), accuracy: 1e-9)
        XCTAssertTrue(s.definition.contains("baseline_p95"))

        // With the idle baseline (median ≈ 58, p95 ≈ 108): threshold = p95 + 50.
        let idle = LatencyStatistics.compute(from: Self.samples([50, 55, 58, 58, 60, 62, 108, 58, 57, 59, 56, 58, 110, 57, 58, 60, 58, 55, 58, 57]))
        let b = SpikeAnalyzer.analyze(Self.samples(series), baseline: idle)!
        XCTAssertEqual(b.baselineSource, "preLoadIdle")
        XCTAssertEqual(b.thresholdMs, idle.rtt!.p95 + 50, accuracy: 1e-9)
        XCTAssertEqual(b.count, 1)
    }

    // MARK: Bufferbloat — only a comparable control probe is a measured condition

    func testIndependentControlProbeGivesFullComparison() {
        let t = StressValidityTests.self
        var dl = t.transfer("cloudflare", round: 1, .download, t.speed(.download, mbps: 300, seconds: 20), loadedMs: 140)
        dl.controlLoadedSamples = (0..<40).map { LatencySample(sequence: $0, offset: 1 + Double($0) * 0.25, rttMs: 95) }
        var s = t.summary([dl])
        s.controlProbe = ProbeDescriptor(target: "8.8.8.8", method: "icmpEcho", protocolName: "ICMP", ipFamily: "IPv4")
        s.controlIdleSamples = Self.samples(Array(repeating: 15, count: 20))
        let c = s.bufferbloatComparison(.download)!
        XCTAssertEqual(c.quality, .full)
        XCTAssertEqual(c.source, "independentControlProbe")
        XCTAssertTrue(c.comparisonTargetSame && c.comparisonMethodSame)
        XCTAssertEqual(c.increaseMs, 80, accuracy: 0.5)

        var r = Fixture.result(.wifi)
        r.kind = .extremeStressTest
        r.stress = s
        let session = DiagnosticSession(title: "t", tests: [SessionTest(label: "A", result: r)])
        let a = RootCauseAnalyzer().analyze(session: session, baselines: nil)
        XCTAssertTrue(a.evidence.codes.contains(.loadedLatencyInflationObserved))
        XCTAssertEqual(a.hypotheses.first { $0.cause == .loadedLatencyInflation }?.likelihood, .supported)
        let text = RawDataExporter.text(r, analysis: a, appVersion: "2.2.0", platform: "iOS")
        for key in ["download_comparison.probe_target=8.8.8.8", "download_comparison.probe_method=icmpEcho", "download_comparison.probe_protocol=ICMP",
                    "download_comparison.probe_ip_family=IPv4", "download_comparison.idle_sample_count=20", "download_comparison.comparison_target_same=true",
                    "download_comparison.comparison_method_same=true", "download_comparison.comparison_quality=full"] {
            XCTAssertTrue(text.contains(key), key)
        }
    }

    func testLimitedComparisonNeverHighConfidence() {
        let ev = [DiagnosticEvidence(code: .onWiFi, statement: "", interface: .wifi),
                  DiagnosticEvidence(code: .loadedLatencyRiseLimitedComparison, statement: ""),
                  DiagnosticEvidence(code: .jitterHigh, statement: ""), DiagnosticEvidence(code: .slowPostLoadRecovery, statement: ""),
                  DiagnosticEvidence(code: .idleLatencyLow, statement: "")]
        let a = RootCauseAnalyzer().analyze(evidence: EvidenceSet(evidence: ev, measuredDimensions: Set(EvidenceDimension.allCases)))
        let h = a.hypotheses.first { $0.cause == .loadedLatencyInflation }!
        XCTAssertNotEqual(h.likelihood, .supported)
        XCTAssertNotEqual(h.likelihood, .likely)
        XCTAssertNotEqual(h.confidenceBand, .high)
        XCTAssertLessThanOrEqual(h.confidence, RootCauseAnalyzer.limitedComparisonCap)
    }

    // MARK: Confidence is an evidence score, not a probability

    func testConfidenceIsNotExportedAsProbability() throws {
        let r = Fixture.result(.wifi, download: 300, upload: 20, latency: 15, loss: 3)
        let analysis = RawDataExporter.analysis(for: r)
        let text = RawDataExporter.text(r, analysis: analysis, appVersion: "2.2.0", platform: "iOS")
        XCTAssertTrue(text.contains("schema_version=3"))
        XCTAssertTrue(text.contains("cause,status,evidence_score_0_100,confidence_band,claim_type,"))
        XCTAssertFalse(text.contains("cause,status,confidence,"))
        XCTAssertTrue(text.contains("evidence_score_0_100 is uncalibrated evidence strength, not a probability"))
        XCTAssertTrue(text.contains("code,kind,dimension,value,unit,claim_type"))
        if let top = analysis.mostLikely {
            XCTAssertTrue(text.contains("most_likely=\(top.cause.rawValue) (\(top.likelihood.rawValue), evidence_score_0_100="))
        }
        for h in analysis.hypotheses {
            XCTAssertTrue((0...100).contains(h.evidenceScore))
            XCTAssertEqual(h.confidenceBand, ConfidenceBand(score: h.confidence))
        }
        XCTAssertFalse(analysis.conclusion.contains("可能性 "), "no probability wording")
        XCTAssertEqual(EvidenceKind.heuristic.claimType, "heuristic_inference")
        XCTAssertEqual(EvidenceKind.notTested.claimType, "not_measured")

        let data = try RawDataExporter.json(r, analysis: analysis, appVersion: "2.2.0", platform: "iOS")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RawDataExport.self, from: data)
        XCTAssertEqual(decoded.version, 3)
        XCTAssertNotNil(decoded.derived)
    }

    func testV1ExportStillDecodes() throws {
        // A v1 JSON has no "derived" and legacy loss verdicts; both must still decode.
        XCTAssertEqual(try JSONDecoder().decode(LossVerdict.self, from: Data("\"noLoss\"".utf8)), .noLoss)
        XCTAssertEqual(try JSONDecoder().decode(LossVerdict.self, from: Data("\"confirmedLoss\"".utf8)), .confirmedLoss)
        let r = Fixture.result(.wifi, download: 100, upload: 10)
        var json = try JSONSerialization.jsonObject(with: RawDataExporter.json(r, analysis: nil, appVersion: "2.1.2", platform: "iOS")) as! [String: Any]
        json["derived"] = nil
        json["version"] = 1
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let decoded = try d.decode(RawDataExport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertNil(decoded.derived)
    }

    // MARK: MTU / traceroute / upload source

    func testMTUIsScopedToTestedPath() {
        var r = Fixture.result(.wifi)
        r.mtu = MTUResult(date: Date(), target: "1.1.1.1", pathMTU: 1500,
                          probes: [MTUProbe(packetSize: 1500, succeeded: true, note: nil), MTUProbe(packetSize: 1501, succeeded: false, note: nil)], method: "icmpDF")
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.pathMTUObserved))
        XCTAssertFalse(codes.contains(.mtuNormal))
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.0", platform: "iOS")
        XCTAssertTrue(text.contains("observed_path_mtu_ipv4_bytes=1500"))
        XCTAssertTrue(text.contains("mtu_blackhole_evidence=false"))
        XCTAssertTrue(text.contains("target=1.1.1.1"))
    }

    func testSingleElevatedHopIsICMPDeprioritization() {
        func hop(_ ttl: Int, _ rtts: [Double?], dest: Bool = false) -> TracerouteHop {
            TracerouteHop(ttl: ttl, address: "10.0.0.\(ttl)", hostname: nil, rttsMs: rtts, reachedDestination: dest)
        }
        // Hop 3 answers 132 / 200 / 9.9 ms (slow ICMP path) but hop 4+ are ~11 ms.
        let hops = [hop(1, [2, 2, 2]), hop(2, [8, 8, 9]), hop(3, [132, 200, 9.9]), hop(4, [11, 11, 12]), hop(5, [12, 12, 12], dest: true)]
        let a = TracerouteAnalyzer.analyze(hops)
        XCTAssertTrue(a.steps.isEmpty, "no persistent increase")
        XCTAssertEqual(a.isolatedHighHops.map(\.ttl), [3])
        var r = Fixture.result(.wifi)
        r.traceroute = TracerouteResult(date: Date(), target: "one.one.one.one", resolvedAddress: "1.1.1.1", hops: hops, reachedDestination: true, method: "icmpTTL")
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertFalse(codes.contains(.routeLatencyStep))
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.0", platform: "iOS")
        XCTAssertTrue(text.contains("isolated_elevated_hops_interpretation=icmpDeprioritization"))
        XCTAssertTrue(text.contains("persistent_latency_steps=\n"), "no persistent step")
        XCTAssertTrue(text.contains("isolated_elevated_hops=3:+"))
    }

    func testServerConfirmedThroughputUsesOneSecondWindows() {
        // 10 Mbps = 1.25 MB/s reported every 0.5 s by the receiver.
        let samples = (0...20).map { ServerByteSample(offset: Double($0) * 0.5, bytes: Int64($0) * 625_000) }
        let t = ServerConfirmedThroughput.make(source: "ndt7.AppInfo.NumBytes", samples: samples)!
        XCTAssertEqual(t.averageMbps, 10, accuracy: 0.01)
        XCTAssertTrue(t.windowMbps.allSatisfy { abs($0 - 10) < 0.01 })
        XCTAssertGreaterThanOrEqual(t.windowMbps.count, 8)
        XCTAssertNotNil(t.stabilityScore)
        XCTAssertNil(ServerConfirmedThroughput.make(source: "x", samples: [ServerByteSample(offset: 0.2, bytes: 10)]))
    }

    // MARK: Mobile data safety

    func testDataLimitsAndEstimateRange() {
        let gb = StressDataLimits.gigabyte
        let limits = StressDataLimits(warningBytes: 8 * gb, hardCapBytes: 10 * gb, downloadCapBytes: 7 * gb, uploadCapBytes: nil)
        XCTAssertTrue(limits.isLimited)
        XCTAssertFalse(StressDataLimits.unlimited.isLimited)
        XCTAssertNil(StressDataLimits.unlimited.remaining(.download, down: 50 * gb, up: 0))
        XCTAssertEqual(limits.remaining(.download, down: 5 * gb, up: 1 * gb), 2 * gb, "download cap is tighter than the hard cap")
        XCTAssertEqual(limits.remaining(.upload, down: 5 * gb, up: 1 * gb), 4 * gb)
        XCTAssertLessThanOrEqual(limits.remaining(.upload, down: 9 * gb, up: 2 * gb)!, 0)

        let nodes = [StressNode.throughputNode(for: ServerDescriptor.builtIn[0]), StressNode.throughputNode(for: .mlabNDT7)] + StressNode.latencyOnlyDefaults
        let e = StressTestPlan.make(totalSeconds: 600, nodes: nodes).trafficEstimate(downloadMbps: 300, uploadMbps: 50)
        XCTAssertLessThan(e.lowBytes, e.totalBytes)
        XCTAssertGreaterThan(e.highBytes, e.totalBytes)
        XCTAssertEqual(Double(e.highBytes) / Double(e.lowBytes), 1.3 / 0.7, accuracy: 0.01)
    }
}
