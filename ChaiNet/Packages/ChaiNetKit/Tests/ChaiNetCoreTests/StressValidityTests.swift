import XCTest
@testable import ChaiNetCore

/// Regressions from the v2.1.1 Extreme Stress Test raw export.
final class StressValidityTests: XCTestCase {
    // MARK: Builders

    /// Constant-rate timeline of `seconds` at `mbps` (100 ms samples).
    static func speed(_ direction: TransferDirection, mbps: Double, seconds: Double, totalBytes: Int64? = nil,
                      diagnostics: TransferDiagnostics? = nil, batched: Bool = false) -> SpeedResult {
        let n = Int(seconds * 10)
        let flat = totalBytes.map { $0 / Int64(n) } ?? Int64(mbps * 1_000_000 / 8 * 0.1)
        let remainder = totalBytes.map { $0 - flat * Int64(n) } ?? 0
        var cumulative: Int64 = 0
        let samples = (0..<n).map { i -> SpeedSample in
            let b = (batched ? (i % 4 == 3 ? flat * 4 : 0) : flat) + (i == n - 1 ? remainder : 0)
            cumulative += b
            return SpeedSample(offset: Double(i + 1) * 0.1, intervalDuration: 0.1, intervalBytes: b, cumulativeBytes: cumulative, activeStreams: 16)
        }
        var r = SpeedResult(direction: direction, samples: samples, summary: SpeedCalculator.summarize(samples: samples, warmupDuration: 1),
                            streamChanges: [StreamChange(offset: 0, streams: 16)], wasCancelled: false)
        r.diagnostics = diagnostics
        r.validity = TransferValidator.evaluate(r)
        return r
    }

    /// The exact v2.1.1 case: 16,509 bytes in 26.8 s (0.005 Mbps), HTTP 200 with tiny bodies.
    static func cloudflareRound2Tiny() -> SpeedResult {
        var d = TransferDiagnostics()
        d.requestsStarted = 48; d.responses = 48; d.completedOK = 48
        d.statusCounts = ["200": 48]; d.contentTypes = ["application/octet-stream"]
        d.expectedBytesPerRequest = 25_000_000; d.smallestResponseBytes = 0; d.tinyResponses = 48
        d.perStreamBytes = Array(repeating: 1031, count: 16)
        return speed(.download, mbps: 0.005, seconds: 26.8, totalBytes: 16_509, diagnostics: d)
    }

    static func transfer(_ node: String, round: Int, _ dir: TransferDirection, _ s: SpeedResult, loadedMs: Double?, attempt: Int = 1) -> StressTransferResult {
        StressTransferResult(nodeID: node, round: round, direction: dir, method: node == "mlab-ndt7" ? "NDT7 WebSocket x1" : "HTTP x16", speed: s,
                             loadedLatency: loadedMs.map { Fixture.latency(median: $0) }, loadedSamples: nil, error: nil, attempt: attempt)
    }

    static func summary(_ transfers: [StressTransferResult], controls: [LossProbeResult] = [], stressLoss: Double = 0) -> StressSummary {
        let nodes = [StressNode.throughputNode(for: ServerDescriptor.builtIn[0]), StressNode.throughputNode(for: .mlabNDT7)] + StressNode.latencyOnlyDefaults
        let ctrl = controls.isEmpty ? ["cf", "google", "quad9"].map { LossConfirmationTests.probe($0, loss: 0) } : controls
        return StressSummary(plan: StressTestPlan.make(totalSeconds: 300, nodes: nodes), configuredSeconds: 300, actualSeconds: 300, nodes: nodes,
                             transfers: transfers, phases: [], stressProbe: LossConfirmationTests.probe("stress", loss: stressLoss, stress: true),
                             controlProbes: ctrl, preLoadLatency: Fixture.latency(median: 20), preLoadSamples: nil,
                             postLoadLatency: [Fixture.latency(median: 22)], postLoadSamples: [], warnings: [])
    }

    // MARK: Priority 1 — transfer validity

    func testTinyResponseIsInvalid() {
        let r = Self.cloudflareRound2Tiny()
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.validity?.reason, .insufficientPayload)
        var noDiagnostics = r
        noDiagnostics.diagnostics = nil
        XCTAssertEqual(TransferValidator.evaluate(noDiagnostics).reason, .insufficientPayload, "byte floor alone catches it")
    }

    func testStatusRules() {
        var d = TransferDiagnostics()
        d.statusCounts = ["429": 5]
        XCTAssertEqual(TransferValidator.evaluate(Self.speed(.download, mbps: 0.001, seconds: 5, diagnostics: d)).reason, .rateLimited)
        d.statusCounts = ["503": 5]
        XCTAssertEqual(TransferValidator.evaluate(Self.speed(.download, mbps: 0.001, seconds: 5, diagnostics: d)).reason, .endpointFailure)
        d.statusCounts = ["403": 5]
        XCTAssertEqual(TransferValidator.evaluate(Self.speed(.download, mbps: 0.001, seconds: 5, diagnostics: d)).reason, .unexpectedResponse)
        d.statusCounts = ["200": 5]; d.contentTypes = ["text/html; charset=utf-8"]
        XCTAssertEqual(TransferValidator.evaluate(Self.speed(.download, mbps: 50, seconds: 5, diagnostics: d)).reason, .unexpectedResponse)
        XCTAssertTrue(Self.speed(.download, mbps: 431, seconds: 26.8).isValid)
        XCTAssertTrue(Self.speed(.upload, mbps: 2, seconds: 10).isValid, "a slow but real link is valid")
    }

    func testInvalidTransferExcludedEverywhere() {
        let cf1 = Self.transfer("cloudflare", round: 1, .download, Self.speed(.download, mbps: 431, seconds: 26.8), loadedMs: 60)
        let cf2 = Self.transfer("cloudflare", round: 2, .download, Self.cloudflareRound2Tiny(), loadedMs: 400)
        let cf2retry = Self.transfer("cloudflare", round: 2, .download, Self.cloudflareRound2Tiny(), loadedMs: 380, attempt: 2)
        let ml1 = Self.transfer("mlab-ndt7", round: 1, .download, Self.speed(.download, mbps: 200, seconds: 10), loadedMs: 50)
        let ml2 = Self.transfer("mlab-ndt7", round: 2, .download, Self.speed(.download, mbps: 190, seconds: 10), loadedMs: 50)
        let ul = [1, 2].map { Self.transfer("cloudflare", round: $0, .upload, Self.speed(.upload, mbps: 40, seconds: 20), loadedMs: 45) }
        let s = Self.summary([cf1, cf2, cf2retry, ml1, ml2] + ul)

        XCTAssertEqual(s.invalidTransfers().count, 2)
        XCTAssertEqual(s.failedSlots().count, 1, "retry also failed")
        XCTAssertEqual(s.transfers(.download).count, 3)
        // Aggregate: Cloudflare = round 1 only (431), not averaged with 0.005.
        XCTAssertEqual(s.downloadAggregate!.values.first { $0.nodeID == "cloudflare" }!.mbps, 431, accuracy: 1)
        // Degradation uses nodes valid in both rounds (M-Lab only): (200 − 190) / 200.
        XCTAssertEqual(s.throughputDegradationPercent!, 5, accuracy: 0.5)
        // Loaded latency / bufferbloat from real loads only (400 / 380 ms excluded).
        XCTAssertEqual(s.loadedLatencyMs(.download)!, 50, accuracy: 0.5, "median of 60 / 50 / 50 — 400 and 380 excluded")
        XCTAssertFalse(cf2.loadValid)
        XCTAssertEqual(s.scoreConfidence, .medium)
        XCTAssertTrue((s.excludedInvalidMetrics ?? []).contains { $0.contains("cloudflare round 2 download") && $0.contains("insufficientPayload") })
        // Traffic totals still count what really moved.
        XCTAssertEqual(s.totalDownloadBytes, [cf1, cf2, cf2retry, ml1, ml2].reduce(0) { $0 + $1.bytes })

        var r = Fixture.result(.nr)
        r.kind = .extremeStressTest
        r.stress = s
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.serverTransferInvalid))
        XCTAssertFalse(codes.contains(.allServerHealthChecksPassed), "nodes were never health-checked in this fixture")

        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.1.2", platform: "iOS")
        XCTAssertTrue(text.contains("[stress_invalid_transfers]"))
        XCTAssertTrue(text.contains("cloudflare,2,1,download,HTTP x16,false,insufficientPayload,false,16509"))
        XCTAssertTrue(text.contains("scope=stress_aggregate_of_valid_transfers"))
        XCTAssertTrue(text.contains("score_confidence=medium"))
    }

    func testRelativeCrossCheckCatchesImplausiblySlowRound() {
        // 0.5 Mbps for 10 s = 625 kB (above the absolute floor) but < 1 % of the same node's 431 Mbps.
        let a = Self.transfer("cloudflare", round: 1, .download, Self.speed(.download, mbps: 431, seconds: 20), loadedMs: 60)
        let b = Self.transfer("cloudflare", round: 2, .download, Self.speed(.download, mbps: 0.5, seconds: 10), loadedMs: 60)
        XCTAssertTrue(b.isValid)
        let s = Self.summary([a, b])
        XCTAssertEqual(s.invalidTransfers().map(\.round), [2])
    }

    func testServerSpecificNotRuledOutWhileTransferInvalid() {
        let ev = [DiagnosticEvidence(code: .onCellular, statement: "", interface: .cellular),
                  DiagnosticEvidence(code: .allServersNormal, statement: ""), DiagnosticEvidence(code: .serverTransferInvalid, statement: "")]
        let a = RootCauseAnalyzer().analyze(evidence: EvidenceSet(evidence: ev, measuredDimensions: Set(EvidenceDimension.allCases)))
        XCTAssertNotEqual(a.hypotheses.first { $0.cause == .serverOrRouteSpecific }?.likelihood, .ruledOut)
        let clean = RootCauseAnalyzer().analyze(evidence: EvidenceSet(evidence: Array(ev.prefix(2)), measuredDimensions: Set(EvidenceDimension.allCases)))
        XCTAssertEqual(clean.hypotheses.first { $0.cause == .serverOrRouteSpecific }?.likelihood, .ruledOut)
    }

    // MARK: Priority 2 — upload sampling artifact

    func testBatchedUploadStabilityUnavailable() {
        let dl = Self.transfer("cloudflare", round: 1, .download, Self.speed(.download, mbps: 400, seconds: 20), loadedMs: 50)
        let ul = Self.transfer("cloudflare", round: 1, .upload, Self.speed(.upload, mbps: 60, seconds: 20, batched: true), loadedMs: 110)
        XCTAssertTrue(ul.isValid, "batching is a measurement limitation, not an invalid transfer")
        XCTAssertEqual(ul.speed?.summary.samplingArtifactDetected, true)
        let s = Self.summary([dl, ul])
        XCTAssertNil(s.stability(.upload))
        XCTAssertEqual(s.stabilityUnavailableReason(.upload), "measurementSamplingArtifact")
        XCTAssertEqual(s.uploadAggregate!.medianMbps, ul.speed!.summary.averageMbps, accuracy: 1e-9, "bytes / elapsed time")

        var r = Fixture.result(.nr)
        r.stress = s
        XCTAssertNil(r.metrics.uploadStability)
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertFalse(codes.contains(.uploadUnstable))
        XCTAssertFalse(DiagnosticsEngine().diagnose(r.metrics).contains { $0.code == .unstableUpload })
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.1.2", platform: "iOS")
        XCTAssertTrue(text.contains("stability=unavailable"))
        XCTAssertTrue(text.contains("stability_reason=measurementSamplingArtifact"))

        // Same for a normal speed test: OBS doesn't downgrade on an unavailable stability.
        var normal = Fixture.result(.wifi)
        normal.upload = ul.speed
        XCTAssertNil(normal.metrics.uploadStability)
        let obs = OBSSuitabilityCalculator.evaluate(upload: ul.speed!, idleLatency: nil, uploadLoadedLatency: nil, score: nil)
        XCTAssertFalse(obs.warnings.contains { $0.contains("不穩定") })
        XCTAssertEqual(obs.sustainedMbps, ul.speed!.summary.averageMbps, accuracy: 1e-9)
    }

    // MARK: Priority 3 — QUIC is not a packet-loss probe

    func testQUICFailureDoesNotMakeLossInconclusive() {
        var quic = LossConfirmationTests.probe("quic", loss: 100)
        quic.method = "quicHandshake"
        let controls = ["cf", "google", "quad9"].map { LossConfirmationTests.probe($0, loss: 0, count: 150) } + [quic]
        let c = LossConfirmation.evaluate(stress: LossConfirmationTests.probe("stress", loss: 0, stress: true, count: 1500), controls: controls)
        XCTAssertEqual(c.verdict, .noLoss)
        XCTAssertEqual(c.validControlCount, 3)
        XCTAssertEqual(c.confirmedLossPercent!, 0, accuracy: 1e-9)
        XCTAssertFalse(quic.isPacketLossProbe)
    }

    // MARK: Priority 4 — loaded latency validity

    func testNoBufferbloatGradeWithoutValidLoad() {
        let tiny = Self.transfer("cloudflare", round: 2, .download, Self.cloudflareRound2Tiny(), loadedMs: 300)
        let ul = Self.transfer("cloudflare", round: 1, .upload, Self.speed(.upload, mbps: 40, seconds: 20), loadedMs: 110)
        let s = Self.summary([tiny, ul])
        XCTAssertTrue(s.loadValidTransfers(.download).isEmpty)
        XCTAssertNil(s.loadedLatencyMs(.download))
        XCTAssertNil(s.loadedLatencyIncreaseMs(.download))
        XCTAssertEqual(s.loadedLatencyIncreaseMs(.upload)!, 90, accuracy: 1)

        var r = Fixture.result(.nr)
        r.kind = .extremeStressTest
        r.idleLatency = s.preLoadLatency
        r.stress = s
        r.downloadLoadedLatency = nil
        r.uploadLoadedLatency = Fixture.latency(median: 110)
        r.bufferbloat = BufferbloatCalculator.evaluate(idle: r.idleLatency!, downloadLoaded: nil, uploadLoaded: r.uploadLoadedLatency)
        XCTAssertNil(r.metrics.downloadBloatMs)
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.1.2", platform: "iOS")
        XCTAssertTrue(text.contains("download_grade=unavailable"))
        XCTAssertTrue(text.contains("download_grade_reason=insufficientLoad"))
        XCTAssertTrue(text.contains("download_load_valid=false"))

        // ~90 ms upload inflation is a measured condition: the hypothesis can't be "unlikely".
        let session = DiagnosticSession(title: "t", tests: [SessionTest(label: "A", result: r)])
        let analysis = RootCauseAnalyzer().analyze(session: session, baselines: nil)
        XCTAssertTrue(analysis.evidence.codes.contains(.loadedLatencyInflationObserved))
        let h = analysis.hypotheses.first { $0.cause == .loadedLatencyInflation }!
        XCTAssertTrue([.possible, .likely].contains(h.likelihood), "\(h.likelihood)")
    }

    // MARK: Priority 5 — DNS scoping

    func testDNSResultScoping() {
        func resolver(_ id: String, _ transport: DNSTransport, _ endpoint: String, _ rtts: [Double?]) -> DNSResolverResult {
            let samples = rtts.enumerated().map { LatencySample(sequence: $0.offset, offset: Double($0.offset), rttMs: $0.element) }
            return DNSResolverResult(resolver: DNSResolverDescriptor(id: id, name: id, transport: transport, endpoint: endpoint),
                                     samples: samples, statistics: LatencyStatistics.compute(from: samples), errors: [])
        }
        var r = Fixture.result(.nr)
        let system: [Double?] = [16, 17, 18, 18, 18, 19, 19, 20, 170, 180]   // median ≈ 18, P95 ≈ 175
        let v6: [Double?] = [30, 31, 32, 33, 35, 40, 45, 300, nil, nil]
        r.dns = DNSBenchmarkResult(date: Date(), domains: [], resolvers: [resolver("system", .system, "", system),
                                                                          resolver("cf-v6", .udp, "2606:4700:4700::1111", v6)])
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.systemDNSHealthy))
        XCTAssertTrue(codes.contains(.dnsHighTailLatencyObserved))
        XCTAssertTrue(codes.contains(.alternateIPv6ResolverDegraded))
        XCTAssertFalse(codes.contains(.dnsHealthy))
        let session = DiagnosticSession(title: "t", tests: [SessionTest(label: "A", result: r)])
        let h = RootCauseAnalyzer().analyze(session: session, baselines: nil).hypotheses.first { $0.cause == .dnsResolverIssue }!
        XCTAssertNotEqual(h.likelihood, .ruledOut)
    }

    // MARK: Priority 6 — honour configured duration

    func testBudgetRecycling() {
        XCTAssertEqual(StressBudget.next(remaining: 60, roundCost: 40, extraRoundsDone: 0), .extraRound)
        XCTAssertEqual(StressBudget.next(remaining: 60, roundCost: 40, extraRoundsDone: StressBudget.maxExtraRounds), .extendedMonitoring(seconds: 59))
        XCTAssertEqual(StressBudget.next(remaining: 23, roundCost: 40, extraRoundsDone: 0), .extendedMonitoring(seconds: 22))
        XCTAssertEqual(StressBudget.next(remaining: 2, roundCost: 40, extraRoundsDone: 0), .done)
        XCTAssertEqual(StressBudget.next(remaining: 30, roundCost: 0, extraRoundsDone: 0), .extendedMonitoring(seconds: 29))
        // 300 s configured, 277.1 s used by the planned phases → 22.9 s recycled, ends ≈ 299 s.
        guard case .extendedMonitoring(let s) = StressBudget.next(remaining: 300 - 277.1, roundCost: 60, extraRoundsDone: 0) else { return XCTFail() }
        XCTAssertEqual(277.1 + s, 299, accuracy: 0.5)
    }

    // MARK: Priority 8 — environment-aware recommendations

    func testRecommendationsMatchEnvironment() {
        let cellular: Set<EvidenceCode> = [.onCellular, .on5G, .vpnInactive]
        for t in [RecommendedTest.moveCloserToRouter, .pauseOtherDevices, .disableVPNAndRepeat, .repeatOnCellular, .repeatOn5G] {
            XCTAssertFalse(RootCauseAnalyzer.applicable(t, codes: cellular), "\(t)")
        }
        XCTAssertTrue(RootCauseAnalyzer.applicable(.repeatOnWiFi, codes: cellular))
        XCTAssertTrue(RootCauseAnalyzer.applicable(.repeatOnLTE, codes: cellular))
        XCTAssertTrue(RootCauseAnalyzer.applicable(.moveCloserToRouter, codes: [.onWiFi]))
        XCTAssertTrue(RootCauseAnalyzer.applicable(.disableVPNAndRepeat, codes: [.onWiFi, .vpnActive]))

        let ev = [.onCellular, .on5G, .vpnInactive, .jitterHigh, .lossHigh, .uploadVeryLow].map {
            DiagnosticEvidence(code: $0, statement: "", interface: .cellular)
        }
        let a = RootCauseAnalyzer().analyze(evidence: EvidenceSet(evidence: ev, measuredDimensions: Set(EvidenceDimension.allCases)))
        let all = Set(a.hypotheses.flatMap(\.recommendedNextTests) + a.recommendedTests.map(\.test))
        XCTAssertTrue(all.isDisjoint(with: [.moveCloserToRouter, .pauseOtherDevices, .disableVPNAndRepeat, .repeatOnCellular]), "\(all)")
    }
}
