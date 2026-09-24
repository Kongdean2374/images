import XCTest
@testable import ChaiNetCore

final class StressPlanTests: XCTestCase {
    let nodes = [StressNode.throughputNode(for: ServerDescriptor.builtIn[0]), StressNode.throughputNode(for: .mlabNDT7)]
        + StressNode.latencyOnlyDefaults

    func testRoundsScaleWithDuration() {
        XCTAssertEqual(StressTestPlan.rounds(for: 60), 1)
        XCTAssertEqual(StressTestPlan.rounds(for: 180), 1)
        XCTAssertEqual(StressTestPlan.rounds(for: 300), 2)
        XCTAssertEqual(StressTestPlan.rounds(for: 600), 2)
        XCTAssertEqual(StressTestPlan.rounds(for: 900), 3)
    }

    func testLongerTestsAddRoundsNotJustLongerTransfers() {
        let short = StressTestPlan.make(totalSeconds: 180, nodes: nodes)
        let long = StressTestPlan.make(totalSeconds: 900, nodes: nodes)
        XCTAssertGreaterThan(long.phases.filter { $0.kind == .downloadStress }.count, short.phases.filter { $0.kind == .downloadStress }.count)
        XCTAssertEqual(long.phases.filter { $0.kind == .postLoadRecovery }.count, 3)
        XCTAssertEqual(long.phases(round: 2).filter { $0.kind == .uploadStress }.count, 2)
    }

    func testIntensityNeverDepends() {
        for t in StressTestPlan.presets {
            let p = StressTestPlan.make(totalSeconds: t, nodes: nodes)
            XCTAssertEqual(p.streams, 16)
            XCTAssertEqual(p.stressPacketsPerSecond, 50)
            XCTAssertEqual(p.controlPacketsPerSecond, 5)
            XCTAssertGreaterThanOrEqual(p.transferSeconds, 6)
        }
    }

    func testEstimateTracksRequestForLongTests() {
        for t in [300.0, 600, 900] {
            let p = StressTestPlan.make(totalSeconds: t, nodes: nodes)
            XCTAssertEqual(p.estimatedSeconds, t, accuracy: t * 0.15, "\(t)")
        }
    }

    func testNDT7CappedAt10Seconds() {
        let p = StressTestPlan.make(totalSeconds: 900, nodes: nodes)
        let mlab = p.phases.filter { $0.nodeID == "mlab-ndt7" }
        XCTAssertFalse(mlab.isEmpty)
        XCTAssertTrue(mlab.allSatisfy { $0.seconds <= 10 })
    }

    func testLatencyOnlyProvidersNeverCarryThroughput() {
        let bogus = StressNode(id: "g", name: "Google", provider: .google, host: "www.google.com", capabilities: [.throughput, .latency],
                               server: ServerDescriptor.builtIn[0])
        XCTAssertFalse(bogus.isThroughputCapable)
        let p = StressTestPlan.make(totalSeconds: 300, nodes: nodes + [bogus])
        XCTAssertFalse(p.phases.contains { $0.nodeID == "g" })
        XCTAssertEqual(Set(p.throughputNodes.map(\.provider)), [.cloudflare, .mlab])
        for n in StressNode.latencyOnlyDefaults { XCTAssertFalse(n.isThroughputCapable) }
    }

    func testTrafficEstimate() {
        let p = StressTestPlan.make(totalSeconds: 300, nodes: nodes)
        let dlSeconds = p.phases.filter { $0.kind == .downloadStress }.reduce(0) { $0 + $1.seconds }
        let e = p.trafficEstimate(downloadMbps: 100, uploadMbps: 20)
        XCTAssertEqual(Double(e.downloadBytes), dlSeconds * 12_500_000, accuracy: 1)
        XCTAssertEqual(e.totalBytes, e.downloadBytes + e.uploadBytes)
    }

    func testAssumedRatesFromHistory() {
        let wifi = [Fixture.result(.wifi, download: 200, upload: 40), Fixture.result(.wifi, download: 400, upload: 60), Fixture.result(.lte, download: 20, upload: 5)]
        let a = StressTestPlan.assumedMbps(history: wifi, networkClass: .wifi)
        XCTAssertTrue(a.fromHistory)
        XCTAssertEqual(a.download, 300, accuracy: 1)
        XCTAssertEqual(a.upload, 50, accuracy: 1)
        let none = StressTestPlan.assumedMbps(history: [], networkClass: .nr)
        XCTAssertFalse(none.fromHistory)
        XCTAssertEqual(none.download, StressTestPlan.defaultAssumedMbps(for: .nr).download)
    }

    func testWarningsNeverChangePlan() {
        var net = Fixture.network(.nr, constrained: true)
        net.isExpensive = true
        XCTAssertTrue(StressTestPlan.warnings(for: net).contains { $0.contains("低數據模式") })
        XCTAssertTrue(StressTestPlan.confirmationWarning.contains("最大可用頻寬"))
    }
}

final class LossConfirmationTests: XCTestCase {
    static func probe(_ id: String, loss: Double, stress: Bool = false, count: Int = 100) -> LossProbeResult {
        let lost = Int(loss / 100 * Double(count))
        let samples = (0..<count).map { LatencySample(sequence: $0, offset: Double($0) * 0.2, rttMs: $0 < lost ? nil : 20) }
        return LossProbeResult(id: id, name: id, target: id, method: "icmpEcho",
                               packetsPerSecond: stress ? 50 : 5, isStressProbe: stress, samples: samples)
    }

    func testOnlyStressProbeLosesIsRateLimiting() {
        let c = LossConfirmation.evaluate(stress: Self.probe("s", loss: 8, stress: true), controls: [Self.probe("a", loss: 0), Self.probe("b", loss: 0), Self.probe("c", loss: 0)])
        XCTAssertEqual(c.verdict, .possibleICMPRateLimiting)
        XCTAssertEqual(c.confirmedLossPercent!, 0, accuracy: 1e-9)
        XCTAssertEqual(c.stressLossPercent!, 8, accuracy: 1e-9)
    }

    func testMultiProbeLossIsConfirmed() {
        let c = LossConfirmation.evaluate(stress: Self.probe("s", loss: 6, stress: true), controls: [Self.probe("a", loss: 4), Self.probe("b", loss: 5), Self.probe("c", loss: 0)])
        XCTAssertEqual(c.verdict, .confirmedGeneralPacketLoss)
        XCTAssertEqual(c.confirmedLossPercent!, 4, accuracy: 1e-9, "median of controls")
    }

    func testSingleLossyControlIsEndpointSpecific() {
        let c = LossConfirmation.evaluate(stress: Self.probe("s", loss: 0, stress: true), controls: [Self.probe("a", loss: 10), Self.probe("b", loss: 0), Self.probe("c", loss: 0)])
        XCTAssertEqual(c.verdict, .endpointSpecificLossObserved)
        XCTAssertEqual(c.affectedTargets, ["a"])
        XCTAssertEqual(c.cleanTargets, ["b", "c"])
        XCTAssertEqual(c.confirmedLossPercent!, 0, accuracy: 1e-9)
    }

    func testTooFewControlPacketsIgnored() {
        let c = LossConfirmation.evaluate(stress: Self.probe("s", loss: 10, stress: true), controls: [Self.probe("a", loss: 0, count: 10)])
        XCTAssertEqual(c.verdict, .inconclusive)
        XCTAssertNil(c.confirmedLossPercent)
    }

    func testNoLoss() {
        XCTAssertEqual(LossConfirmation.evaluate(stress: Self.probe("s", loss: 0, stress: true), controls: [Self.probe("a", loss: 0), Self.probe("b", loss: 0)]).verdict, .noConfirmedGeneralPacketLoss)
    }
}

final class CrossProviderAggregateTests: XCTestCase {
    func v(_ id: String, _ mbps: Double, _ p: StressProvider = .cloudflare) -> ServerThroughputValue {
        ServerThroughputValue(nodeID: id, name: id, provider: p, mbps: mbps)
    }

    func testStatistics() {
        let a = CrossProviderAggregate.make(.download, values: [v("a", 100), v("b", 200, .mlab), v("c", 300, .chainet)])!
        XCTAssertEqual(a.meanMbps, 200, accuracy: 1e-9)
        XCTAssertEqual(a.medianMbps, 200, accuracy: 1e-9)
        XCTAssertEqual(a.minMbps, 100)
        XCTAssertEqual(a.maxMbps, 300)
        XCTAssertEqual(a.p10Mbps, 120, accuracy: 1e-9)
        XCTAssertEqual(a.p95Mbps, 290, accuracy: 1e-9)
        XCTAssertEqual(a.variance, 20_000.0 / 3, accuracy: 1e-6)
        XCTAssertTrue(a.largeVariance, "max / min = 3")
    }

    func testConsistent() {
        let a = CrossProviderAggregate.make(.upload, values: [v("a", 50), v("b", 55), v("c", 48)])!
        XCTAssertFalse(a.largeVariance)
        XCTAssertTrue(a.isConsistent)
        XCTAssertNil(CrossProviderAggregate.make(.upload, values: []))
        XCTAssertFalse(CrossProviderAggregate.make(.upload, values: [v("a", 50)])!.isConsistent, "one node is not a comparison")
    }
}

final class StressSummaryTests: XCTestCase {
    static func summary(dl: [String: [Double]], loadedMs: Double = 40, postMs: Double = 22, controlsLoss: [Double] = [0, 0], stressLoss: Double = 0) -> StressSummary {
        let cf = StressNode.throughputNode(for: ServerDescriptor.builtIn[0])
        let ml = StressNode.throughputNode(for: .mlabNDT7)
        let nodes = [cf, ml] + StressNode.latencyOnlyDefaults
        let plan = StressTestPlan.make(totalSeconds: 600, nodes: nodes)
        var transfers: [StressTransferResult] = []
        for (id, rounds) in dl {
            for (i, mbps) in rounds.enumerated() {
                transfers.append(StressTransferResult(nodeID: id, round: i + 1, direction: .download, method: "HTTP x16",
                                                      speed: Fixture.speed(.download, mbps: mbps), loadedLatency: Fixture.latency(median: loadedMs),
                                                      loadedSamples: nil, error: nil))
                transfers.append(StressTransferResult(nodeID: id, round: i + 1, direction: .upload, method: "HTTP x16",
                                                      speed: Fixture.speed(.upload, mbps: mbps / 5), loadedLatency: Fixture.latency(median: loadedMs),
                                                      loadedSamples: nil, error: nil))
            }
        }
        let t = LossConfirmationTests.self
        let controls = controlsLoss.enumerated().map { t.probe("c\($0.offset)", loss: $0.element) }
        return StressSummary(plan: plan, configuredSeconds: 600, actualSeconds: 612, nodes: nodes, transfers: transfers, phases: [],
                             stressProbe: t.probe("stress", loss: stressLoss, stress: true), controlProbes: controls,
                             preLoadLatency: Fixture.latency(median: 20), preLoadSamples: nil,
                             postLoadLatency: [Fixture.latency(median: postMs)], postLoadSamples: [], warnings: [])
    }

    func testTotalsAggregateAndDerived() {
        let s = Self.summary(dl: ["cloudflare": [200, 150], "mlab-ndt7": [100, 80]])
        XCTAssertEqual(s.totalDownloadBytes, s.transfers.filter { $0.direction == .download }.reduce(0) { $0 + $1.bytes })
        XCTAssertGreaterThan(s.totalBytes, s.totalDownloadBytes)
        XCTAssertEqual(s.downloadAggregate?.values.count, 2)
        XCTAssertEqual(s.downloadAggregate!.medianMbps, 132.5, accuracy: 1)
        XCTAssertEqual(s.bufferbloatMs!, 20, accuracy: 0.5)
        XCTAssertEqual(s.recoveryDeltaMs!, 2, accuracy: 0.5)
        XCTAssertEqual(s.throughputDegradationPercent!, (150 - 115) / 150 * 100, accuracy: 1)
        XCTAssertNotNil(s.score)
        XCTAssertEqual(s.testMode, "extremeStressTest")
    }

    func testEvidenceAndMetrics() {
        let s = Self.summary(dl: ["cloudflare": [400, 400], "mlab-ndt7": [100, 100]], postMs: 60, controlsLoss: [0, 0, 0], stressLoss: 10)
        var r = Fixture.result(.wifi)
        r.stress = s
        r.packetLoss = s.stressProbe!.statistics
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.possibleICMPRateLimiting))
        XCTAssertFalse(codes.contains(.lossHigh), "stress-only ICMP loss must not become lossHigh")
        XCTAssertTrue(codes.contains(.largeCrossProviderThroughputVariance))
        XCTAssertTrue(codes.contains(.slowPostLoadRecovery))
        XCTAssertEqual(r.metrics.lossPercent!, 0, accuracy: 1e-9, "metrics use confirmed control loss")
        XCTAssertEqual(r.metrics.downloadMbps!, 250, accuracy: 2)
        XCTAssertEqual(EvidenceCode.possibleICMPRateLimiting.kind, .heuristic)
    }

    func testConfirmedLossEvidence() {
        let s = Self.summary(dl: ["cloudflare": [100]], controlsLoss: [4, 5, 6], stressLoss: 6)
        var r = Fixture.result(.wifi)
        r.stress = s
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.lossHigh))
        XCTAssertFalse(codes.contains(.possibleICMPRateLimiting))
    }

    func testRawExportContainsStressSections() {
        var r = Fixture.result(.wifi)
        r.kind = .extremeStressTest
        r.stress = Self.summary(dl: ["cloudflare": [200, 150], "mlab-ndt7": [100, 80]])
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.1.0", platform: "iOS")
        for key in ["test_mode=extremeStressTest", "configured_duration_s=600", "actual_duration_s=612", "[stress_nodes]", "[stress_phases]",
                    "[stress_transfers_per_server]", "[stress_cross_provider_download]", "inter_server_variance_mbps2=", "High-rate ICMP stress probe",
                    "stress_packet_rate_pps=50", "http_streams_per_transfer=16", "post_load_round_1_median_ms=", "total_bytes=",
                    "raw.stress.cloudflare.round1.download_samples_100ms", "raw.stress.loss_probe.stress"] {
            XCTAssertTrue(text.contains(key), key)
        }
        XCTAssertEqual(TestKind.extremeStressTest.displayName, "極限壓力測試")
    }
}
