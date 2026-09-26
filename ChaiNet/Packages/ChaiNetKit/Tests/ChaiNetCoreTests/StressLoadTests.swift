import XCTest
@testable import ChaiNetCore

/// v3.0 stress-load analyzers: saturation search, recovery, cross-load impact, scores, evidence.
final class StressLoadTests: XCTestCase {
    static func stats(_ mbps: Double, degradation: Double? = nil) -> LoadStats {
        LoadStats(averageMbps: mbps, medianMbps: mbps, p10Mbps: mbps * 0.9, p95Mbps: mbps * 1.05, peakMbps: mbps * 1.1, initialMbps: mbps,
                  finalMbps: degradation.map { mbps * (1 - $0 / 100) }, degradationPercent: degradation, bytes: 1, durationSeconds: 3,
                  samplingArtifact: false)
    }

    static func stage(_ n: Int, _ mbps: Double) -> StreamRampStage {
        StreamRampStage(streamCount: n, throughput: stats(mbps), latency: nil, gainPercent: nil, samples: [])
    }

    /// The spec example: 320 / 510 / 690 / 775 / 808 / 811 / 805 → saturation ≈ 16, not 32.
    func testSaturationSearchPicksPlateauNotMaximumStreams() {
        let stages = zip([1, 2, 4, 8, 16, 24, 32], [320.0, 510, 690, 775, 808, 811, 805]).map { Self.stage($0, $1) }
        let r = StreamRampResult.analyze(direction: .download, method: "HTTP", targetNodeID: "cloudflare", stages: stages)
        XCTAssertTrue(r.saturationDetected)
        XCTAssertEqual(r.saturationStreamCount, 16)
        XCTAssertEqual(r.optimalStreamCount, 16, "fewest streams within 3 % of the best average (808 ≥ 0.97 × 811; 775 is not)")
        XCTAssertEqual(r.maxObservedStreamCount, 32)
        XCTAssertEqual(r.marginalGainPercent!, (805 - 811) / 811 * 100, accuracy: 0.01)
        XCTAssertEqual(r.stages[4].gainPercent!, (808 - 775) / 775 * 100, accuracy: 0.01)
        XCTAssertEqual(r.scalingEfficiency0_100!, (808 - 320) / (811 - 320) * 100, accuracy: 0.1)
        XCTAssertEqual(r.connectionEfficiencyMbpsPerStream!, 808.0 / 16, accuracy: 0.01)
        XCTAssertEqual(r.recommendedStreams, 16)
    }

    func testSaturationNotClaimedWhileStillGrowing() {
        let stages = zip([1, 2, 4, 8], [100.0, 190, 370, 700]).map { Self.stage($0, $1) }
        let r = StreamRampResult.analyze(direction: .download, method: "HTTP", targetNodeID: "x", stages: stages)
        XCTAssertFalse(r.saturationDetected)
        XCTAssertNil(r.saturationStreamCount)
        XCTAssertEqual(r.maxObservedStreamCount, 8)
    }

    func testRampStopRule() {
        XCTAssertFalse(StreamRampResult.shouldStop([nil, 60, 35]))
        XCTAssertFalse(StreamRampResult.shouldStop([nil, 60, 2]), "one flat stage is not enough")
        XCTAssertTrue(StreamRampResult.shouldStop([nil, 60, 2, 1]))
        XCTAssertTrue(StreamRampResult.shouldStop([nil, 60, -5]), "a clear decline stops the ramp")
    }

    // MARK: Recovery

    func testRecoveryTimesAndIncompleteRecovery() {
        let rtts: [Double?] = [120, 90, 60, 30, 21, 20, 21, 20]
        let samples = rtts.enumerated().map { LatencySample(sequence: $0.offset, offset: Double($0.offset) * 0.25, rttMs: $0.element) }
        let r = RecoveryResult.analyze(kind: "final", afterPhase: "burst", plannedSeconds: 2, samples: samples, baselineMedianMs: 20)
        XCTAssertTrue(r.complete)
        XCTAssertEqual(r.recoveryTime10PercentMs!, 1000, accuracy: 0.1, "first of two consecutive ≤ 22 ms at 1.0 s")
        XCTAssertEqual(r.recoveryTime20PercentMs!, 1000, accuracy: 0.1)
        let never = RecoveryResult.analyze(kind: "final", afterPhase: "burst", plannedSeconds: 2,
                                           samples: (0..<8).map { LatencySample(sequence: $0, offset: Double($0) * 0.25, rttMs: 80) },
                                           baselineMedianMs: 20)
        XCTAssertFalse(never.complete)
        XCTAssertNil(never.recoveryTime10PercentMs, "no invented value when latency never recovered")
    }

    // MARK: Multi-destination / full duplex

    func testMultiDestinationOnlySuggestsLimitation() {
        let d = [DestinationLoad(nodeID: "cloudflare", name: "CF", provider: .cloudflare, method: "HTTP", streamCount: 16, throughput: Self.stats(500), samples: []),
                 DestinationLoad(nodeID: "mlab-ndt7", name: "M-Lab", provider: .mlab, method: "NDT7 WebSocket", streamCount: 1, throughput: Self.stats(300), samples: [])]
        let m = MultiDestinationResult(plannedSeconds: 10, destinations: d, latency: nil, bestSingleStandardMbps: 520)
        XCTAssertEqual(m.aggregateMbps, 800)
        XCTAssertFalse(m.methodEquivalent)
        XCTAssertTrue(m.singleDestinationLimitationPossible)
    }

    func testFullDuplexImpactAndScores() {
        var report = StressLoadReport()
        report.idleControlMedianMs = 15
        report.fullDuplex = FullDuplexResult(targetNodeID: "cloudflare", downloadStreams: 16, uploadStreams: 16, plannedSeconds: 20,
                                             download: Self.stats(560), upload: Self.stats(40), downloadOnlyReferenceMbps: 800, uploadOnlyReferenceMbps: 50,
                                             latency: LatencyUnderLoad(medianMs: 165, p95Ms: 220, p99Ms: 260, jitterMs: 12, lossPercent: 0,
                                                                       sampleCount: 80, idleMedianMs: 15, inflationMs: 150),
                                             downloadSamples: [], uploadSamples: [])
        let impact = try! XCTUnwrap(report.crossLoadImpact)
        XCTAssertEqual(impact.downloadLossDueToUploadPercent!, 30, accuracy: 0.01)
        XCTAssertEqual(impact.uploadLossDueToDownloadPercent!, 20, accuracy: 0.01)
        XCTAssertEqual(report.worstLoadInflationMs, 150)
        let scores = report.scores
        XCTAssertLessThan(scores.fullDuplex!, 40)
        XCTAssertEqual(scores.loadedLatency, 25)

        // 800 Mbps but +150 ms under full duplex: gaming / voice must drop.
        var fast = Fixture.result(.wifi, download: 800, upload: 50, latency: 12)
        let before = fast.scores.gaming!
        fast.stressLoad = report
        fast.evaluate()
        XCTAssertLessThanOrEqual(fast.scores.gaming!, 45)
        XCTAssertLessThan(fast.scores.gaming!, before)
        XCTAssertLessThanOrEqual(fast.scores.voice!, 50)
        // Stable 400 Mbps link keeps a high gaming score.
        var steady = Fixture.result(.wifi, download: 400, upload: 50, latency: 12)
        var calm = StressLoadReport()
        calm.fullDuplex = FullDuplexResult(targetNodeID: "cloudflare", downloadStreams: 16, uploadStreams: 16, plannedSeconds: 20,
                                           download: Self.stats(390), upload: Self.stats(48), downloadOnlyReferenceMbps: 400, uploadOnlyReferenceMbps: 50,
                                           latency: LatencyUnderLoad(medianMs: 20, p95Ms: 25, p99Ms: 30, jitterMs: 2, lossPercent: 0,
                                                                     sampleCount: 80, idleMedianMs: 15, inflationMs: 5),
                                           downloadSamples: [], uploadSamples: [])
        steady.stressLoad = calm
        steady.evaluate()
        XCTAssertGreaterThan(steady.scores.gaming!, fast.scores.gaming!)
    }

    // MARK: Evidence stays at "loaded latency", never a scheduler / carrier claim

    func testFullDuplexLatencyIsOnlyLoadedLatencyEvidence() {
        var r = Fixture.result(.nr, download: 800, upload: 50, latency: 15)
        var report = StressLoadReport()
        report.idleControlMedianMs = 15
        report.fullDuplex = FullDuplexResult(targetNodeID: "cloudflare", downloadStreams: 16, uploadStreams: 16, plannedSeconds: 20,
                                             download: Self.stats(560), upload: Self.stats(40), downloadOnlyReferenceMbps: 800, uploadOnlyReferenceMbps: 50,
                                             latency: LatencyUnderLoad(medianMs: 95, p95Ms: 130, p99Ms: 160, jitterMs: 9, lossPercent: 0,
                                                                       sampleCount: 80, idleMedianMs: 15, inflationMs: 80),
                                             downloadSamples: [], uploadSamples: [])
        report.environment = EnvironmentRecord(samples: [
            EnvironmentSample(offset: 0, thermalState: "nominal", batteryPercent: 80, batteryState: "unplugged", lowPowerMode: false, interface: "cellular", radioTechnology: nil),
            EnvironmentSample(offset: 100, thermalState: "serious", batteryPercent: 76, batteryState: "unplugged", lowPowerMode: false, interface: "cellular", radioTechnology: nil),
        ])
        r.stressLoad = report
        let a = RootCauseAnalyzer().analyze(session: Fixture.session([r]), baselines: nil)
        let codes = a.evidence.codes
        XCTAssertTrue(codes.contains(.loadCorrelatedLatencyInflation))
        XCTAssertTrue(codes.contains(.fullDuplexInterference))
        XCTAssertTrue(codes.contains(.thermalStateChangedDuringLoad))
        XCTAssertEqual(EvidenceCode.fullDuplexInterference.kind, .derived)
        XCTAssertNotEqual(a.hypotheses.first { $0.cause == .deviceOrOSEnvironment }?.likelihood, .likely, "thermal is correlation only")
        XCTAssertNotEqual(a.hypotheses.first { $0.cause == .cellularUplinkCongestion }?.likelihood, .supported)
        let text = RawDataExporter.text(r, analysis: a, appVersion: "3.0.0", platform: "iOS")
        XCTAssertTrue(text.contains("queue_location=unknown"))
        XCTAssertTrue(text.contains("thermal_state_peak=serious"))
        XCTAssertTrue(text.contains("battery_percent_start=80"))
        XCTAssertTrue(text.contains("dl_loss_due_to_ul_percent=30.0"))
        XCTAssertTrue(text.contains("# Correlation only"))
    }

    func testPlanBudgetFor300Seconds() {
        let nodes = [StressNode.throughputNode(for: ServerDescriptor.builtIn[0]), StressNode.throughputNode(for: .mlabNDT7)] + StressNode.latencyOnlyDefaults
        let p = StressTestPlan.make(totalSeconds: 300, nodes: nodes)
        XCTAssertEqual(p.estimatedSeconds, 300, accuracy: 15)
        XCTAssertEqual(p.durationAdjustmentReason(configuredSeconds: 300) == "none" || abs(p.estimatedSeconds - 300) < 15, true)
    }
}
