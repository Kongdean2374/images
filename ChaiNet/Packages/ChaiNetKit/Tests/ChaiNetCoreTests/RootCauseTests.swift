import XCTest
@testable import ChaiNetCore

final class HypothesisCatalogTests: XCTestCase {
    func testEveryCauseHasExactlyOneModel() {
        for cause in RootCause.allCases {
            XCTAssertEqual(HypothesisCatalog.all.filter { $0.cause == cause }.count, 1, "\(cause)")
        }
    }

    func testModelsAreWellFormed() {
        for m in HypothesisCatalog.all {
            XCTAssertFalse(m.weights.isEmpty, "\(m.cause) needs evidence weights")
            XCTAssertTrue(m.weights.values.contains { $0 > 0 }, "\(m.cause) needs supporting evidence")
            XCTAssertGreaterThan(m.confidenceCap, 0.5)
            XCTAssertLessThanOrEqual(m.confidenceCap, 0.95, "no hypothesis may claim certainty")
            XCTAssertFalse(m.verificationTests.isEmpty, "\(m.cause) needs a verification test")
            XCTAssertTrue(m.ruledOutBy.isDisjoint(with: Set(m.weights.filter { $0.value > 0 }.keys)),
                          "\(m.cause): a code can't both support and rule out")
        }
    }

    func testRadioHypothesesAreCappedBecauseIOSHidesSignalMetrics() {
        for cause in [RootCause.cellularRadioQuality, .deviceOrOSEnvironment] {
            XCTAssertLessThan(HypothesisCatalog.model(for: cause)!.confidenceCap, RootCauseAnalyzer.likelyThreshold,
                              "\(cause) can never be 'likely' without radio / hardware telemetry")
        }
    }
}

/// Rule tests that drive the analyzer directly with evidence (no measurements needed).
final class RootCauseRuleTests: XCTestCase {
    let analyzer = RootCauseAnalyzer()

    func ev(_ codes: [EvidenceCode], interface: InterfaceKind? = nil) -> [DiagnosticEvidence] {
        codes.map { DiagnosticEvidence(code: $0, statement: $0.rawValue, interface: $0.dimension == .environment || $0.dimension.isPerTest ? interface : nil) }
    }

    func analyze(_ codes: [EvidenceCode], interface: InterfaceKind? = .cellular, measured: Set<EvidenceDimension> = Set(EvidenceDimension.allCases)) -> RootCauseAnalysis {
        analyzer.analyze(evidence: EvidenceSet(evidence: ev(codes, interface: interface), measuredDimensions: measured))
    }

    func hyp(_ a: RootCauseAnalysis, _ c: RootCause) -> DiagnosticHypothesis { a.hypotheses.first { $0.cause == c }! }

    /// The user's reference case: 524/1.1 Mbps on cellular, unstable upload, 8 % loss, 137 ms
    /// jitter, same behaviour on multiple servers, but 11 ms idle latency.
    func testCellularUplinkCongestionReferenceCase() {
        let a = analyze([.onCellular, .on5G, .downloadHigh, .uploadVeryLow, .asymmetricRatio, .uploadUnstable, .lossHigh, .lossSevere,
                         .jitterHigh, .allServersAnomalous, .idleLatencyLow, .cellularRadioMetricsUnavailable, .vpnInactive, .notConstrained])
        let h = hyp(a, .cellularUplinkCongestion)
        XCTAssertEqual(h.likelihood, .likely)
        XCTAssertGreaterThanOrEqual(h.confidence, 0.80)
        XCTAssertLessThanOrEqual(h.confidence, 0.85)
        XCTAssertTrue(h.contradictingEvidence.contains { $0.code == .idleLatencyLow })
        XCTAssertTrue(h.supportingEvidence.contains { $0.code == .allServersAnomalous })
        XCTAssertTrue(h.recommendedNextTests.contains(.repeatOnLTE))
        XCTAssertEqual(a.mostLikely?.layer, .accessLink)
        // Server-specific issue is excluded because every server behaves the same.
        XCTAssertEqual(hyp(a, .serverOrRouteSpecific).likelihood, .ruledOut)
        // No Wi-Fi test in this session → Wi-Fi causes are *not tested*, never ruled out.
        XCTAssertEqual(hyp(a, .wifiRadioQuality).likelihood, .notTested)
        XCTAssertEqual(hyp(a, .nrSpecificIssue).likelihood, .unlikely, "on 5G but no LTE comparison yet → no support")
        // No cross-interface comparison → device problem can't be "likely".
        XCTAssertNotEqual(hyp(a, .deviceOrOSEnvironment).likelihood, .likely)
        // Radio quality stays at most "possible" because iOS exposes no RSRP / SINR.
        XCTAssertEqual(hyp(a, .cellularRadioQuality).likelihood, .possible)
        // Plan limit is contradicted by instability and loss.
        XCTAssertNotEqual(hyp(a, .asymmetricPlanLimit).likelihood, .likely)
    }

    func testSingleServerAnomalyPointsToServerOrRoute() {
        let a = analyze([.onWiFi, .singleServerAnomalous, .downloadNormal, .uploadNormal, .vpnInactive], interface: .wifi)
        XCTAssertEqual(a.mostLikely?.cause, .serverOrRouteSpecific)
        XCTAssertEqual(hyp(a, .ispOrCarrierCongestion).likelihood, .unlikely)
    }

    func testAllServersAnomalousRaisesISP() {
        let a = analyze([.onWiFi, .allServersAnomalous, .lossHigh, .deviatesFromBaseline, .downloadNormal], interface: .wifi)
        let isp = hyp(a, .ispOrCarrierCongestion)
        XCTAssertTrue([Likelihood.likely, .possible].contains(isp.likelihood))
        XCTAssertEqual(hyp(a, .serverOrRouteSpecific).likelihood, .ruledOut)
    }

    func testIPv6OnlyDegradationIsIPv6Routing() {
        let a = analyze([.onWiFi, .ipv6DegradedOnly], interface: .wifi)
        XCTAssertEqual(hyp(a, .ipv6RoutingIssue).likelihood, .likely)
        XCTAssertEqual(hyp(a, .ipv4RoutingIssue).likelihood, .ruledOut)
        XCTAssertEqual(a.mostLikely?.cause, .ipv6RoutingIssue)
    }

    func testEquivalentFamiliesRuleOutBoth() {
        let a = analyze([.onWiFi, .ipFamiliesEquivalent], interface: .wifi)
        XCTAssertEqual(hyp(a, .ipv6RoutingIssue).likelihood, .ruledOut)
        XCTAssertEqual(hyp(a, .ipv4RoutingIssue).likelihood, .ruledOut)
    }

    func testWiFiNormalCellularDegradedLowersDeviceAndWiFi() {
        let a = analyze([.onWiFi, .onCellular, .wifiNormalCellularDegraded, .uploadVeryLow, .lossHigh], interface: .cellular)
        XCTAssertEqual(hyp(a, .deviceOrOSEnvironment).likelihood, .unlikely)
        XCTAssertLessThan(hyp(a, .deviceOrOSEnvironment).confidence, 0.1)
        XCTAssertEqual(hyp(a, .wifiRadioQuality).likelihood, .ruledOut)
    }

    func testLTENormal5GDegraded() {
        let a = analyze([.onCellular, .on5G, .onLTE, .lteNormalNRDegraded])
        XCTAssertEqual(hyp(a, .nrSpecificIssue).likelihood, .likely)
        XCTAssertLessThan(hyp(a, .cellularSubsystem).confidence, 0.2)
        XCTAssertLessThan(hyp(a, .deviceOrOSEnvironment).confidence, 0.05)
    }

    func testAllCellularDegradedWiFiNormal() {
        let a = analyze([.onWiFi, .onCellular, .onLTE, .on5G, .allCellularDegradedWifiNormal, .wifiNormalCellularDegraded])
        XCTAssertEqual(hyp(a, .cellularSubsystem).likelihood, .likely)
        XCTAssertLessThanOrEqual(hyp(a, .cellularSubsystem).confidence, 0.8)
        XCTAssertNotEqual(hyp(a, .deviceOrOSEnvironment).likelihood, .likely)
    }

    func testAllInterfacesDegradedRaisesDeviceOnlyToCap() {
        let a = analyze([.onWiFi, .onCellular, .allInterfacesDegraded, .allServersAnomalous])
        let device = hyp(a, .deviceOrOSEnvironment)
        XCTAssertEqual(device.likelihood, .possible, "raised, but never 'likely' without hardware telemetry")
        XCTAssertLessThanOrEqual(device.confidence, 0.65)
    }

    func testAllInterfacesNormalRulesOutDevice() {
        let a = analyze([.onWiFi, .onCellular, .allInterfacesNormal])
        XCTAssertEqual(hyp(a, .deviceOrOSEnvironment).likelihood, .ruledOut)
    }

    func testMissingDimensionGivesInsufficientEvidence() {
        // No interface comparison was run → device hypothesis is *not tested*.
        let a = analyze([.onWiFi, .lossHigh], interface: .wifi, measured: [.loss, .latency, .environment])
        XCTAssertEqual(hyp(a, .deviceOrOSEnvironment).likelihood, .notTested)
        XCTAssertTrue(hyp(a, .deviceOrOSEnvironment).missingDimensions.contains(.interfaceCompare))
        XCTAssertEqual(hyp(a, .ipv6RoutingIssue).likelihood, .notTested)
        XCTAssertTrue(hyp(a, .ipv6RoutingIssue).recommendedNextTests.contains(.compareIPFamilies))
    }

    func testAttemptedButInconclusiveIsInsufficientEvidence() {
        // A cross-server check ran but only one endpoint answered → insufficient, not "not tested".
        let set = EvidenceSet(evidence: ev([.onWiFi, .lossHigh], interface: .wifi), measuredDimensions: [.loss, .latency, .environment],
                              attemptedDimensions: [.crossServer])
        let a = analyzer.analyze(evidence: set)
        XCTAssertEqual(hyp(a, .serverOrRouteSpecific).likelihood, .insufficientEvidence)
    }

    func testSingleMetricIsNotEnoughForLikely() {
        // Only "upload very low" on Wi-Fi: may be a plan limit or congestion, but no single cause is likely.
        let a = analyze([.onWiFi, .uploadVeryLow], interface: .wifi)
        XCTAssertTrue(a.likely.isEmpty, "got \(a.likely.map(\.cause))")
    }

    func testAsymmetricPlanLimitWhenUploadIsStableAndClean() {
        let a = analyze([.onWiFi, .downloadHigh, .uploadLow, .asymmetricRatio, .uploadStable, .lossNone, .noBufferbloat, .matchesBaseline,
                         .allServersNormal], interface: .wifi)
        XCTAssertEqual(hyp(a, .asymmetricPlanLimit).likelihood, .likely)
        XCTAssertEqual(hyp(a, .routerBufferbloat).likelihood, .ruledOut)
        XCTAssertNotEqual(hyp(a, .fixedLineUplinkCongestion).likelihood, .likely)
    }

    func testBufferbloat() {
        let a = analyze([.onWiFi, .uploadBufferbloat, .idleLatencyLow], interface: .wifi)
        XCTAssertEqual(hyp(a, .routerBufferbloat).likelihood, .likely)
    }

    func testDNS() {
        XCTAssertEqual(hyp(analyze([.onWiFi, .dnsFailures], interface: .wifi), .dnsResolverIssue).likelihood, .likely)
        XCTAssertEqual(hyp(analyze([.onWiFi, .dnsHealthy], interface: .wifi), .dnsResolverIssue).likelihood, .ruledOut)
    }

    func testVPNApplicability() {
        // VPN detection is heuristic → "not detected" makes it unlikely, never ruled out.
        XCTAssertEqual(hyp(analyze([.onWiFi, .vpnInactive], interface: .wifi), .vpnOverhead).likelihood, .unlikely)
        XCTAssertEqual(hyp(analyze([.onWiFi], interface: .wifi), .vpnOverhead).likelihood, .notTested)
        XCTAssertTrue([Likelihood.likely, .possible].contains(hyp(analyze([.onWiFi, .vpnActive, .idleLatencyHigh, .mtuReduced], interface: .wifi), .vpnOverhead).likelihood))
    }

    func testLowDataMode() {
        XCTAssertEqual(hyp(analyze([.onWiFi, .lowDataMode], interface: .wifi), .lowDataModeThrottling).likelihood, .likely)
        XCTAssertEqual(hyp(analyze([.onWiFi, .notConstrained], interface: .wifi), .lowDataModeThrottling).likelihood, .ruledOut)
    }

    func testQUICBlocked() {
        XCTAssertEqual(hyp(analyze([.onWiFi, .quicBlocked], interface: .wifi), .udpQuicBlocked).likelihood, .likely)
        XCTAssertEqual(hyp(analyze([.onWiFi, .http3Negotiated], interface: .wifi), .udpQuicBlocked).likelihood, .ruledOut)
    }

    func testMTU() {
        // One normal IPv4 path = "no issue observed on the tested path", not a global exclusion.
        XCTAssertEqual(hyp(analyze([.onWiFi, .mtuNormal], interface: .wifi), .mtuTunnelIssue).likelihood, .unlikely)
        XCTAssertNotEqual(hyp(analyze([.onWiFi, .mtuReduced], interface: .wifi), .mtuTunnelIssue).likelihood, .ruledOut)
    }

    func testOutage() {
        XCTAssertEqual(hyp(analyze([.onWiFi, .connectionDrops, .pathChanged], interface: .wifi), .intermittentOutage).likelihood, .likely)
        XCTAssertEqual(hyp(analyze([.onWiFi, .noDropsObserved], interface: .wifi), .intermittentOutage).likelihood, .unlikely)
    }

    func testServerCapacity() {
        XCTAssertEqual(hyp(analyze([.onWiFi, .serverThroughputOutlierLow], interface: .wifi), .serverCapacityLimit).likelihood, .likely)
        XCTAssertEqual(hyp(analyze([.onWiFi, .crossServerConsistentThroughput], interface: .wifi), .serverCapacityLimit).likelihood, .ruledOut)
    }

    func testRegionSpecificRouting() {
        let a = analyze([.onWiFi, .regionSpecificAnomaly, .multipleServersAnomalous], interface: .wifi)
        XCTAssertTrue([Likelihood.likely, .possible].contains(hyp(a, .routingTransit).likelihood))
    }

    func testWiFiRadioQuality() {
        let a = analyze([.onWiFi, .jitterHigh, .lossRandom, .lossHigh, .latencySpikesFrequent, .cellularNormalWifiDegraded, .onCellular], interface: .wifi)
        XCTAssertEqual(hyp(a, .wifiRadioQuality).likelihood, .likely)
        XCTAssertLessThanOrEqual(hyp(a, .wifiRadioQuality).confidence, 0.85)
    }

    func testCellularEvidenceDoesNotLeakIntoWiFiHypotheses() {
        // Bad metrics only on the cellular test must not support the Wi-Fi hypothesis.
        var evidence = [DiagnosticEvidence(code: .onWiFi, statement: "", interface: .wifi),
                        DiagnosticEvidence(code: .onCellular, statement: "", interface: .cellular)]
        evidence += [EvidenceCode.jitterHigh, .lossRandom, .latencySpikesFrequent].map { DiagnosticEvidence(code: $0, statement: "", interface: .cellular) }
        let a = analyzer.analyze(evidence: EvidenceSet(evidence: evidence, measuredDimensions: Set(EvidenceDimension.allCases)))
        XCTAssertTrue(hyp(a, .wifiRadioQuality).supportingEvidence.isEmpty)
    }

    func testNo5GTestIsNotTestedNotRuledOut() {
        let a = analyze([.onCellular, .onLTE, .no5GTests, .uploadVeryLow])
        XCTAssertEqual(hyp(a, .nrSpecificIssue).likelihood, .notTested)
        XCTAssertNotNil(hyp(a, .nrSpecificIssue).statusReason)
    }

    func testNormalUploadDoesNotRuleOutCellularUplinkQueueing() {
        let a = analyze([.onCellular, .uploadNormal, .uploadBufferbloat, .jitterHigh, .allServersAnomalous])
        XCTAssertNotEqual(hyp(a, .cellularUplinkCongestion).likelihood, .ruledOut)
        XCTAssertTrue(hyp(a, .cellularUplinkCongestion).contradictingEvidence.contains { $0.code == .uploadNormal })
        XCTAssertNotEqual(hyp(analyze([.onWiFi, .uploadNormal], interface: .wifi), .fixedLineUplinkCongestion).likelihood, .ruledOut)
    }

    func testBufferbloatLayerIsPathQueueingNotLocalNetwork() {
        let a = analyze([.onCellular, .onLTE, .uploadBufferbloat, .idleLatencyLow])
        XCTAssertEqual(hyp(a, .routerBufferbloat).layer, .pathQueueing)
        XCTAssertFalse(hyp(a, .routerBufferbloat).title.contains("Wi-Fi"))
    }

    func testHeuristicOrUntestedEvidenceNeverRulesOut() {
        for h in analyze([.onCellular, .vpnInactive, .no5GTests, .noCellularTests, .cellularRadioMetricsUnavailable, .noBaseline,
                          .interfaceProbeUnavailable]).ruledOut {
            XCTAssertTrue(h.rulingOutEvidence.allSatisfy { $0.kind == .measured || $0.kind == .derived }, "\(h.cause)")
        }
    }

    func testRepeatedEvidenceCountsOnce() {
        let once = analyze([.onWiFi, .dnsSlow], interface: .wifi)
        let twice = analyze([.onWiFi, .dnsSlow, .dnsSlow, .dnsSlow], interface: .wifi)
        XCTAssertEqual(hyp(once, .dnsResolverIssue).confidence, hyp(twice, .dnsResolverIssue).confidence, accuracy: 1e-12)
    }

    func testHypothesesOrderedAndConclusionPresent() {
        let a = analyze([.onWiFi, .ipv6DegradedOnly, .vpnInactive], interface: .wifi)
        let ranks = a.hypotheses.map(\.likelihood)
        XCTAssertEqual(ranks, ranks.sorted())
        XCTAssertTrue(a.conclusion.contains("IPv6"))
        XCTAssertFalse(a.recommendedTests.isEmpty)
    }
}

private extension EvidenceDimension {
    var isPerTest: Bool { ![.crossServer, .ipFamily, .interfaceCompare, .radioCompare].contains(self) }
}

final class CrossTestAnalyzerTests: XCTestCase {
    let analyzer = CrossTestAnalyzer()

    func testSingleServerAnomaly() {
        var r = Fixture.result(.wifi, latency: 20, server: "a")
        r.crossValidation = [Fixture.check("b", median: 22), Fixture.check("c", median: 18, loss: 10), Fixture.check("d", median: 25)]
        let c = analyzer.compareServers(Fixture.session([r]))
        XCTAssertEqual(c.verdict, .singleServerAnomalous)
        XCTAssertEqual(c.entries.filter(\.isAnomalous).map(\.id), ["c"])
    }

    func testAllServersAnomalous() {
        var r = Fixture.result(.lte, latency: 20, loss: 8, server: "a")
        r.crossValidation = [Fixture.check("b", median: 22, loss: 6), Fixture.check("c", median: 18, loss: 9)]
        XCTAssertEqual(analyzer.compareServers(Fixture.session([r])).verdict, .allServersAnomalous)
    }

    func testPeerLatencyIsInformationalNotAnomalous() {
        // Different anycast providers: 71 ms vs a 20 ms peer is "higher relative to peers", not an anomaly.
        var r = Fixture.result(.wifi, latency: 20, server: "a")
        r.crossValidation = [Fixture.check("b", median: 69), Fixture.check("c", median: 71)]
        let c = analyzer.compareServers(Fixture.session([r]))
        XCTAssertTrue(c.entries.filter(\.isAnomalous).isEmpty)
        XCTAssertEqual(c.entries.filter(\.higherLatencyRelativeToPeers).map(\.id), ["c"])
        XCTAssertEqual(c.verdict, .allNormal)
    }

    func testEndpointBaselineDeviationIsAnomalous() {
        var r = Fixture.result(.wifi, latency: 20, server: "a")
        r.crossValidation = [Fixture.check("b", median: 90), Fixture.check("c", median: 18)]
        let baseline = EndpointBaseline(endpointID: "b", network: .wifi,
                                        latency: MetricBaseline(metric: .latencyMs, count: 20, median: 25, mad: 1, p10: 23, p90: 27))
        let c = analyzer.compareServers(Fixture.session([r]), endpointBaselines: [baseline])
        XCTAssertEqual(c.entries.filter(\.isAnomalous).map(\.id), ["b"])
    }

    func testUnavailableEndpointIsExcluded() {
        var r = Fixture.result(.wifi, latency: 20, server: "a")
        r.crossValidation = [Fixture.check("b", median: 22),
                             EndpointCheck(id: "x", name: "x", host: "x", region: "r", method: .icmpEcho, statistics: nil, error: "no route", isPrimary: false)]
        let c = analyzer.compareServers(Fixture.session([r]))
        XCTAssertEqual(c.entries.first { $0.id == "x" }?.status, .notMeasured)
        XCTAssertEqual(c.verdict, .allNormal)
    }

    func testRegionSpecific() {
        var r = Fixture.result(.wifi, latency: 20, server: "a")
        r.crossValidation = [Fixture.check("us1", region: "US", median: 300, loss: 5), Fixture.check("us2", region: "US", median: 320, loss: 6),
                             Fixture.check("jp", region: "Tokyo", median: 40)]
        let c = analyzer.compareServers(Fixture.session([r]))
        XCTAssertEqual(c.verdict, .multipleServersAnomalous)
        XCTAssertEqual(c.anomalousRegion, "US")
    }

    func testInsufficientWithOneServer() {
        XCTAssertEqual(analyzer.compareServers(Fixture.session([Fixture.result(.wifi)])).verdict, .insufficientData)
    }

    func testThroughputOutlier() {
        let a = Fixture.result(.wifi, download: 400, server: "a")
        let b = Fixture.result(.wifi, download: 100, server: "b")
        let c = analyzer.compareServers(Fixture.session([a, b]))
        XCTAssertEqual(c.throughputOutlierIDs, ["b"])
        XCTAssertEqual(c.throughputConsistent, false)
    }

    func testIPv6Degraded() {
        var r = Fixture.result(.wifi)
        r.ipFamilyComparison = IPFamilyComparisonResult(target: "x", method: .tcpConnect, ipv4: Fixture.latency(median: 20),
                                                        ipv6: Fixture.latency(median: 90), ipv4Error: nil, ipv6Error: nil)
        XCTAssertEqual(analyzer.compareIPFamilies(Fixture.session([r])).verdict, .ipv6Degraded)
    }

    func testIPv6LossDegraded() {
        var r = Fixture.result(.wifi)
        r.ipFamilyComparison = IPFamilyComparisonResult(target: "x", method: .tcpConnect, ipv4: Fixture.latency(median: 20),
                                                        ipv6: Fixture.latency(median: 21, lossPercent: 5), ipv4Error: nil, ipv6Error: nil)
        XCTAssertEqual(analyzer.compareIPFamilies(Fixture.session([r])).verdict, .ipv6Degraded)
    }

    func testIPFamiliesFromForcedTests() {
        var v4 = Fixture.result(.wifi, latency: 20); v4.ipFamilyPreference = .ipv4Only
        var v6 = Fixture.result(.wifi, latency: 22); v6.ipFamilyPreference = .ipv6Only
        XCTAssertEqual(analyzer.compareIPFamilies(Fixture.session([v4, v6])).verdict, .equivalent)
    }

    func testIPv6Unavailable() {
        var r = Fixture.result(.wifi)
        r.ipFamilyComparison = IPFamilyComparisonResult(target: "x", method: .tcpConnect, ipv4: Fixture.latency(median: 20), ipv6: nil,
                                                        ipv4Error: nil, ipv6Error: "No route")
        XCTAssertEqual(analyzer.compareIPFamilies(Fixture.session([r])).verdict, .ipv6Unavailable)
    }

    func testInterfaceVerdicts() {
        let wifiOK = Fixture.result(.wifi, download: 300, upload: 50)
        let lteBad = Fixture.result(.lte, download: 50, upload: 1)
        let nrBad = Fixture.result(.nr, download: 500, upload: 1, loss: 8)
        let nrOK = Fixture.result(.nr, download: 500, upload: 50)
        let lteOK = Fixture.result(.lte, download: 80, upload: 20)
        let wifiBad = Fixture.result(.wifi, download: 5, upload: 1, loss: 10)

        XCTAssertEqual(analyzer.compareInterfaces(Fixture.session([wifiOK, lteBad])).verdict, .wifiNormalCellularDegraded)
        XCTAssertEqual(analyzer.compareInterfaces(Fixture.session([wifiOK, lteBad, nrBad])).verdict, .allCellularDegradedWifiNormal)
        XCTAssertEqual(analyzer.compareInterfaces(Fixture.session([wifiBad, lteOK])).verdict, .cellularNormalWifiDegraded)
        XCTAssertEqual(analyzer.compareInterfaces(Fixture.session([wifiBad, lteBad])).verdict, .allDegraded)
        XCTAssertEqual(analyzer.compareInterfaces(Fixture.session([wifiOK, lteOK])).verdict, .allNormal)
        XCTAssertEqual(analyzer.compareInterfaces(Fixture.session([lteOK, nrBad])).radioVerdict, .lteNormalNRDegraded)
        XCTAssertEqual(analyzer.compareInterfaces(Fixture.session([lteBad, nrOK])).radioVerdict, .nrNormalLTEDegraded)
        XCTAssertEqual(analyzer.compareInterfaces(Fixture.session([wifiOK])).verdict, .insufficientData)
    }

    func testUnavailableInterfaceProbeIsNotDegraded() {
        var wifi = Fixture.result(.wifi, download: 300, upload: 50)
        wifi.interfaceCompare = [InterfaceProbeResult(interface: .cellular, tcpConnect: nil, error: "行動網路 無法使用或未連線")]
        let i = analyzer.compareInterfaces(Fixture.session([wifi]))
        XCTAssertEqual(i.verdict, .insufficientData, "only Wi-Fi was measured")
        XCTAssertEqual(i.unavailable.count, 1)
        XCTAssertFalse(i.groups.contains { $0.networkClass == .cellularOther })

        // Bad Wi-Fi + unavailable cellular must not become "all interfaces degraded".
        var badWifi = Fixture.result(.wifi, download: 5, upload: 1, loss: 10)
        badWifi.interfaceCompare = wifi.interfaceCompare
        XCTAssertNotEqual(analyzer.compareInterfaces(Fixture.session([badWifi])).verdict, .allDegraded)
    }

    func testHealthThresholds() {
        XCTAssertFalse(TestHealthEvaluator.assess(Fixture.result(.wifi, download: 100, upload: 20)).isDegraded)
        XCTAssertTrue(TestHealthEvaluator.assess(Fixture.result(.wifi, download: 100, upload: 2)).isDegraded)
        XCTAssertTrue(TestHealthEvaluator.assess(Fixture.result(.wifi, loss: 3)).isDegraded)
        XCTAssertTrue(TestHealthEvaluator.assess(Fixture.result(.wifi, jitter: 40)).isDegraded)
    }
}

final class EvidenceExtractorTests: XCTestCase {
    let extractor = EvidenceExtractor()

    func codes(_ r: TestResult) -> Set<EvidenceCode> {
        Set(extractor.extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
    }

    func testThroughputEvidence() {
        let c = codes(Fixture.result(.nr, download: 524, upload: 1.1, uploadJitter: 0.8))
        XCTAssertTrue(c.isSuperset(of: [.downloadHigh, .uploadVeryLow, .asymmetricRatio, .uploadUnstable, .onCellular, .on5G,
                                        .cellularRadioMetricsUnavailable]))
        XCTAssertFalse(c.contains(.onWiFi))
    }

    func testLatencyAndLossEvidence() {
        let c = codes(Fixture.result(.wifi, latency: 11, jitter: 137, loss: 8, burst: true))
        XCTAssertTrue(c.isSuperset(of: [.idleLatencyLow, .jitterHigh, .lossHigh, .lossSevere, .lossBursty]))
        let clean = codes(Fixture.result(.wifi, latency: 150, jitter: 1, loss: 0))
        XCTAssertTrue(clean.isSuperset(of: [.idleLatencyHigh, .jitterLow, .lossNone]))
    }

    func testBufferbloatEvidence() {
        XCTAssertTrue(codes(Fixture.result(.wifi, uploadBloat: 250)).contains(.uploadBufferbloat))
        let none = codes(Fixture.result(.wifi, uploadBloat: 5, downloadBloat: 10))
        XCTAssertTrue(none.contains(.noBufferbloat))
    }

    func testVPNEvidence() {
        XCTAssertTrue(codes(Fixture.result(.wifi, vpn: .detected)).contains(.vpnActive))
        XCTAssertTrue(codes(Fixture.result(.wifi, vpn: .notDetected)).contains(.vpnInactive))
        let unknown = codes(Fixture.result(.wifi, vpn: .unknown))
        XCTAssertFalse(unknown.contains(.vpnActive) || unknown.contains(.vpnInactive))
    }

    func testSessionLevelEvidence() {
        let set = extractor.extract(from: Fixture.session([Fixture.result(.wifi)]))
        XCTAssertTrue(set.codes.contains(.noCellularTests))
        XCTAssertFalse(set.measuredDimensions.contains(.crossServer))
    }

    func testEndToEndReferenceSession() {
        // Test A: 5G with the reference symptoms; cross-checked against 3 endpoints that show the same loss.
        var a = Fixture.result(.nr, download: 524, upload: 1.1, uploadJitter: 0.8, latency: 11, jitter: 137, loss: 8, uploadBloat: 180)
        a.crossValidation = [Fixture.check("b", median: 14, loss: 7), Fixture.check("c", median: 16, loss: 9), Fixture.check("d", median: 12, loss: 6)]
        let analysis = RootCauseAnalyzer().analyze(session: Fixture.session([a]), baselines: nil)
        XCTAssertEqual(analysis.mostLikely?.cause, .cellularUplinkCongestion)
        XCTAssertTrue(analysis.evidence.codes.contains(.allServersAnomalous))
        XCTAssertTrue(analysis.ruledOut.contains { $0.cause == .serverOrRouteSpecific })
    }
}

final class BaselineAndAnomalyTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func history(count: Int, download: Double, latency: Double, hour: Int = 20) -> [TestResult] {
        (0..<count).map { i in
            let date = Date(timeIntervalSince1970: 1_700_000_000 - Double(i) * 86_400).addingTimeInterval(0)
            let d = utc.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
            return Fixture.result(.wifi, download: download + Double(i % 3), upload: 50, latency: latency + Double(i % 2), date: d)
        }
    }

    func testTimeBuckets() {
        func at(_ h: Int) -> TimeOfDayBucket {
            TimeOfDayBucket(date: utc.date(bySettingHour: h, minute: 0, second: 0, of: Date(timeIntervalSince1970: 0))!, calendar: utc)
        }
        XCTAssertEqual(at(3), .night)
        XCTAssertEqual(at(9), .morning)
        XCTAssertEqual(at(15), .afternoon)
        XCTAssertEqual(at(21), .evening)
    }

    func testRegionRounding() {
        XCTAssertEqual(BaselineKey.region(for: GeoPoint(latitude: 25.0478, longitude: 121.5319, horizontalAccuracy: 5)), "25.0,121.5")
        XCTAssertNil(BaselineKey.region(for: nil))
    }

    func testBuildRequiresMinimumSamples() {
        let engine = BaselineEngine(minimumSamples: 5)
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        XCTAssertTrue(engine.build(from: history(count: 4, download: 300, latency: 10), now: now, calendar: utc).baselines.isEmpty)
        let store = engine.build(from: history(count: 10, download: 300, latency: 10), now: now, calendar: utc)
        let b = store.baselines.first { $0.key == BaselineKey(network: .wifi, timeBucket: nil, region: nil) }!
        XCTAssertEqual(b.metric(.downloadMbps)!.median, 301, accuracy: 1)
    }

    func testBaselineIgnoresOldResults() {
        let engine = BaselineEngine(minimumSamples: 5, maximumAgeDays: 3)
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        XCTAssertTrue(engine.build(from: history(count: 10, download: 300, latency: 10), now: now, calendar: utc).baselines.isEmpty)
    }

    func testAnomalyDetection() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let store = BaselineEngine().build(from: history(count: 20, download: 300, latency: 10), now: now, calendar: utc)
        let d = utc.date(bySettingHour: 21, minute: 0, second: 0, of: now)!
        let bad = Fixture.result(.wifi, download: 40, upload: 50, latency: 80, date: d)
        let comparison = AnomalyDetector().compare(bad, store: store, calendar: utc)
        XCTAssertNotNil(comparison.baseline)
        let metrics = Set(comparison.anomalies.map(\.metric))
        XCTAssertTrue(metrics.contains(.downloadMbps))
        XCTAssertTrue(metrics.contains(.latencyMs))
        XCTAssertFalse(metrics.contains(.uploadMbps))

        let better = Fixture.result(.wifi, download: 900, upload: 50, latency: 5, date: d)
        XCTAssertTrue(AnomalyDetector().compare(better, store: store, calendar: utc).anomalies.isEmpty, "improvements are not anomalies")
    }

    func testRobustZFloors() {
        // MAD 0 → σ̂ = max(0, 0.15 × 20, 5) = 5 ms → 35 ms is z = 3 (not > 3)
        let b = MetricBaseline(metric: .latencyMs, count: 10, median: 20, mad: 0, p10: 20, p90: 20)
        XCTAssertEqual(AnomalyDetector().robustZ(value: 35, baseline: b), 3, accuracy: 1e-9)
        let t = MetricBaseline(metric: .downloadMbps, count: 10, median: 100, mad: 0, p10: 100, p90: 100)
        // σ̂ = max(0, 10, 1) = 10 → 60 Mbps is z = 4
        XCTAssertEqual(AnomalyDetector().robustZ(value: 60, baseline: t), 4, accuracy: 1e-9)
    }

    func testBaselineEvidenceInSession() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let store = BaselineEngine().build(from: history(count: 20, download: 300, latency: 10), now: now, calendar: utc)
        let d = utc.date(bySettingHour: 21, minute: 0, second: 0, of: now)!
        let set = EvidenceExtractor().extract(from: Fixture.session([Fixture.result(.wifi, download: 40, upload: 50, latency: 10, date: d)]),
                                              baselines: store, calendar: utc)
        XCTAssertTrue(set.codes.contains(.deviatesFromBaseline))
        XCTAssertTrue(set.measuredDimensions.contains(.baseline))
    }

    func testTimelineThroughputDip() {
        var r = Fixture.result(.wifi, download: 100)
        for i in 20..<25 { r.download!.samples[i].intervalBytes = 1_000 }
        let events = AnomalyDetector().timelineEvents(r)
        XCTAssertEqual(events.filter { $0.kind == .throughputDip }.count, 1)
    }
}

final class DiagnosticReportTests: XCTestCase {
    func makeReport() -> (DiagnosticReport, DiagnosticReportGenerator) {
        var a = Fixture.result(.nr, download: 524, upload: 1.1, uploadJitter: 0.8, latency: 11, jitter: 137, loss: 8)
        a.location = GeoPoint(latitude: 25, longitude: 121, horizontalAccuracy: 5)
        a.crossValidation = [Fixture.check("b", median: 14, loss: 7), Fixture.check("c", median: 16, loss: 9)]
        let session = Fixture.session([a, Fixture.result(.wifi, download: 300, upload: 50)])
        let analysis = RootCauseAnalyzer().analyze(session: session, baselines: nil)
        let gen = DiagnosticReportGenerator()
        return (gen.makeReport(session: session, analysis: analysis, appVersion: "1.0", platform: "iOS 18", includeLocation: false), gen)
    }

    func testTextReportSections() {
        let (report, gen) = makeReport()
        let text = gen.text(report)
        XCTAssertTrue(text.hasPrefix("ChaiNet Diagnostic Report v1"))
        for section in ["Session summary", "Environment", "Statistics", "Raw measurements", "Timeline events", "Anomalies",
                        "Cross-test comparisons", "Evidence", "Diagnostic hypotheses", "Ruled-out causes", "Suggested next tests",
                        "Technical conclusion", "Platform limitations"] {
            XCTAssertTrue(text.contains(section), "missing \(section)")
        }
        XCTAssertTrue(text.contains("rsrp=unavailable"), "unavailable radio metrics must be explicit")
        XCTAssertTrue(text.contains("p99="))
    }

    func testJSONRoundTripKeepsRawDataAndStripsLocation() throws {
        let (report, gen) = makeReport()
        let data = try gen.json(report)
        let decoded = try DiagnosticReportGenerator.decode(data)
        XCTAssertEqual(decoded.metadata.schema, "chainet.diagnostic-report")
        XCTAssertEqual(decoded.rawTests.count, 2)
        XCTAssertEqual(decoded.rawTests[0].result.download?.samples.count, 50, "full timeline preserved")
        XCTAssertNil(decoded.rawTests[0].result.location)
        XCTAssertEqual(decoded.analysis.hypotheses.count, RootCause.allCases.count)
    }
}
