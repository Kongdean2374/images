import XCTest
@testable import ChaiNetCore

/// v2.4.0: traffic projection, scoped server / route inference, unambiguous latency groups.
final class StressInterpretationTests: XCTestCase {
    static let nodes = [StressNode.throughputNode(for: ServerDescriptor.builtIn[0]), StressNode.throughputNode(for: .mlabNDT7)] + StressNode.latencyOnlyDefaults

    // MARK: 1. Traffic estimate / projection

    func testEstimateRangeCoversFastLinks() {
        let plan = StressTestPlan.make(totalSeconds: 300, nodes: Self.nodes)
        let e = plan.trafficEstimate(downloadMbps: 400, uploadMbps: 60, networkClass: .nr)
        // The reported case moved 58 % more than the 400 / 60 Mbps point estimate.
        XCTAssertGreaterThan(Double(e.highBytes), 1.58 * Double(e.totalBytes))
        XCTAssertEqual(e.ceilingDownloadMbps, 1600)
        XCTAssertEqual(e.ceilingUploadMbps, 250)
        XCTAssertLessThan(e.lowBytes, e.totalBytes)
        // Without a network class the old ±30 % range stays (backward compatible).
        let plain = plan.trafficEstimate(downloadMbps: 400, uploadMbps: 60)
        XCTAssertNil(plain.ceilingBytes)
        XCTAssertEqual(Double(plain.highBytes) / Double(plain.totalBytes), 1.3, accuracy: 0.01)
    }

    func testProjectionFormula() {
        // 1 GB used, 60 s download left at 800 Mbps (6 GB) + 20 s upload at 100 Mbps (0.25 GB).
        let p = StressTrafficProjection.project(usedBytes: 1_000_000_000, remainingSeconds: [.download: 60, .upload: 20],
                                                observedMbps: [.download: 800, .upload: 100])
        XCTAssertEqual(p, 1_000_000_000 + 6_000_000_000 + 250_000_000)
    }

    func testProjectionExported() {
        let t = StressValidityTests.self
        var s = t.summary([t.transfer("cloudflare", round: 1, .download, t.speed(.download, mbps: 300, seconds: 20), loadedMs: 40)])
        let original = s.plan.trafficEstimate(downloadMbps: 400, uploadMbps: 60, networkClass: .nr)
        s.trafficEstimate = original
        var p = StressTrafficProjection(original: original)
        p.updatedEstimateBytes = 6_500_000_000
        p.updatedBasis = "afterRound1ObservedThroughput"
        p.observedDownloadMbps = 640
        p.warning = "projectedExceedsOriginalEstimate"
        s.trafficProjection = p
        var r = Fixture.result(.nr)
        r.kind = .extremeStressTest
        r.stress = s
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.4.0", platform: "iOS")
        for key in ["original_estimate_bytes=\(original.totalBytes)", "updated_estimate_bytes=6500000000",
                    "updated_estimate_basis=afterRound1ObservedThroughput", "actual_usage_bytes=", "actual_vs_original_estimate_percent=",
                    "projection_warning=projectedExceedsOriginalEstimate", "estimate_range_ceiling_mbps=download=1600 upload=250"] {
            XCTAssertTrue(text.contains(key), key)
        }
    }

    // MARK: 2. Server / route inference stays scoped

    /// 1.1.1.1 ICMP loss + higher latency on an independent validation endpoint, peers clean.
    func testIndependentEndpointLossIsNotServerRootCause() {
        var r = Fixture.result(.nr, download: 600, upload: 90, latency: 20, server: "a")
        r.crossValidation = [Fixture.check("cf-1.1.1.1", median: 40, loss: 4), Fixture.check("google-8.8.8.8", median: 16),
                             Fixture.check("quad9-9.9.9.9", median: 60)]
        let a = RootCauseAnalyzer().analyze(session: Fixture.session([r]), baselines: nil)
        let codes = a.evidence.codes
        XCTAssertFalse(codes.contains(.singleServerAnomalous), "an independent anycast endpoint is not the speed-test server")
        XCTAssertTrue(codes.contains(.endpointSpecificBehaviorObserved))
        let server = a.hypotheses.first { $0.cause == .serverOrRouteSpecific }!
        XCTAssertNotEqual(server.confidenceBand, .high)
        XCTAssertFalse([Likelihood.likely, .supported].contains(server.likelihood))
        XCTAssertNotEqual(a.mostLikely?.cause, .serverOrRouteSpecific)
    }

    func testServerHypothesisNeedsReproductionForHighConfidence() {
        func analyze(_ codes: [EvidenceCode]) -> DiagnosticHypothesis {
            let ev = codes.map { DiagnosticEvidence(code: $0, statement: "", interface: $0.dimension == .environment ? .wifi : nil) }
            return RootCauseAnalyzer().analyze(evidence: EvidenceSet(evidence: ev, measuredDimensions: Set(EvidenceDimension.allCases)))
                .hypotheses.first { $0.cause == .serverOrRouteSpecific }!
        }
        let single = analyze([.onWiFi, .singleServerAnomalous])
        XCTAssertLessThanOrEqual(single.confidence, 0.6)
        XCTAssertNotEqual(single.confidenceBand, .high)
        let reproduced = analyze([.onWiFi, .singleServerAnomalous, .serverUnhealthy])
        XCTAssertGreaterThan(reproduced.confidence, 0.6, "a server-level measurement can raise it")
    }

    func testICMPPolicyIsASeparateHypothesis() {
        let ev = [DiagnosticEvidence(code: .onWiFi, statement: "", interface: .wifi),
                  DiagnosticEvidence(code: .possibleICMPRateLimiting, statement: ""),
                  DiagnosticEvidence(code: .endpointSpecificLossObserved, statement: "")]
        let a = RootCauseAnalyzer().analyze(evidence: EvidenceSet(evidence: ev, measuredDimensions: Set(EvidenceDimension.allCases)))
        let icmp = a.hypotheses.first { $0.cause == .icmpRateLimitingOrPolicy }!
        XCTAssertTrue([Likelihood.possible, .likely].contains(icmp.likelihood))
        XCTAssertLessThanOrEqual(icmp.confidence, 0.6)
        XCTAssertNotEqual(a.hypotheses.first { $0.cause == .serverOrRouteSpecific }!.confidenceBand, .high)
    }

    // MARK: 3. Latency groups are never mixed

    func testReferenceAndControlLatencyAreSeparateGroups() {
        let t = StressValidityTests.self
        var dl = t.transfer("cloudflare", round: 1, .download, t.speed(.download, mbps: 300, seconds: 20), loadedMs: 136)
        dl.loadedSamples = (0..<40).map { LatencySample(sequence: $0, offset: 1 + Double($0) * 0.25, rttMs: 136) }
        dl.controlLoadedSamples = (0..<40).map { LatencySample(sequence: $0, offset: 1 + Double($0) * 0.25, rttMs: 58) }
        var s = t.summary([dl])
        s.referenceProbe = ProbeDescriptor(target: "speed.cloudflare.com", method: "httpPing", protocolName: "HTTPS/TCP", ipFamily: "system")
        s.controlProbe = ProbeDescriptor(target: "8.8.8.8", method: "icmpEcho", protocolName: "ICMP", ipFamily: "IPv4")
        s.controlIdleSamples = (0..<20).map { LatencySample(sequence: $0, offset: Double($0) * 0.25, rttMs: 15.5) }
        var r = Fixture.result(.nr)
        r.kind = .extremeStressTest
        r.stress = s
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.4.0", platform: "iOS")

        func section(_ name: String) -> String {
            guard let start = text.range(of: "[\(name)]\n") else { return "" }
            let rest = text[start.upperBound...]
            return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
        }
        let recovery = section("stress_latency_recovery")
        XCTAssertTrue(recovery.contains("reference_preload_median_ms="))
        XCTAssertTrue(recovery.contains("transfer_endpoint_loaded_download_median_ms=136.000"))
        XCTAssertTrue(recovery.contains("comparison_group_id=httpPing|HTTPS/TCP|speed.cloudflare.com|system"))
        XCTAssertFalse(recovery.contains("increase_ms="), "no delta in the reference group section")
        XCTAssertFalse(recovery.contains("\npre_load_median_ms="))

        let bloat = section("stress_bufferbloat_comparison")
        XCTAssertTrue(bloat.contains("comparison_group_id=icmpEcho|ICMP|8.8.8.8|IPv4"))
        XCTAssertTrue(bloat.contains("control_idle_median_ms=15.500"))
        XCTAssertTrue(bloat.contains("control_download_loaded_median_ms=58.000"))
        XCTAssertTrue(bloat.contains("control_download_increase_ms=42.500"))
        XCTAssertFalse(bloat.contains("136"), "reference-endpoint values never appear next to control deltas")

        // Generic sections carry the id too.
        XCTAssertTrue(text.contains("comparison_group_id=icmpEcho|ICMP|8.8.8.8|IPv4"))
        XCTAssertEqual(r.latencyProvenance(.downloadLoaded)?.comparisonGroupID, "icmpEcho|ICMP|8.8.8.8|IPv4")
    }
}
