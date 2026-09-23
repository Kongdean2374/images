import XCTest
@testable import ChaiNetCore

final class QUICClassifierTests: XCTestCase {
    func o(_ host: String, ms: Double? = nil, _ f: QUICFailureKind? = nil, tcp: Bool? = true) -> QUICProbeOutcome {
        QUICProbeOutcome(host: host, handshakeMs: ms, failure: f, detail: nil, tcpReachable: tcp)
    }

    func testSingleFailureIsNotBlocking() {
        XCTAssertEqual(QUICClassifier.classify([o("a", .timeout)]), .endpointFailure)
    }

    func testAnySuccessIsWorking() {
        XCTAssertEqual(QUICClassifier.classify([o("a", .timeout), o("b", ms: 30)]), .working)
    }

    func testMultiEndpointTimeoutsWithTCPIsProbableBlocking() {
        XCTAssertEqual(QUICClassifier.classify([o("a", .timeout), o("b", .timeout), o("c", .timeout)]), .probableUDPBlocking)
        XCTAssertEqual(QUICClassifier.classify([o("a", .timeout, tcp: false), o("b", .timeout, tcp: false)]), .endpointFailure,
                       "TCP also failing is not UDP-specific blocking")
    }

    func testSameProtocolErrorIsImplementationFailure() {
        XCTAssertEqual(QUICClassifier.classify([o("a", .protocolError), o("b", .protocolError)]), .implementationFailure)
        XCTAssertEqual(QUICClassifier.classify([o("a", .protocolError), o("b", .timeout)]), .endpointFailure)
        XCTAssertEqual(QUICClassifier.classify([]), .notTested)
    }
}

final class ReportConsistencyTests: XCTestCase {
    let generator = DiagnosticReportGenerator()

    func report(_ session: DiagnosticSession, baselines: BaselineStore? = nil) -> DiagnosticReport {
        let analysis = RootCauseAnalyzer().analyze(session: session, baselines: baselines)
        return generator.makeReport(session: session, analysis: analysis, appVersion: "t", platform: "t", includeLocation: false)
    }

    func protocolProbe(proto: HTTPProtocolVersion, quic: [QUICProbeOutcome]) -> ProtocolProbeResult {
        let http = HTTPTimingBreakdown(url: "https://x", dnsMs: 5, tcpConnectMs: 10, tlsMs: 20, ttfbMs: 40, totalMs: 60, negotiatedProtocol: proto,
                                       reusedConnection: false, remoteAddress: nil, localAddress: nil, ipFamily: .ipv4, tlsVersion: "TLS 1.3", statusCode: 200)
        var p = ProtocolProbeResult(date: Date(), host: "x", http: http, http3Attempt: http, quicHandshakeMs: .unavailable(reason: "t"),
                                    tcpConnect: nil, tlsConnect: nil, httpLatency: nil, ipv4Reachable: .available(10), ipv6Reachable: .available(12), errors: [])
        p.quicProbes = quic
        p.quicAssessment = QUICClassifier.classify(quic)
        return p
    }

    func scenarios() -> [DiagnosticSession] {
        var reference = Fixture.result(.nr, download: 524, upload: 1.1, uploadJitter: 0.8, latency: 11, jitter: 137, loss: 8, uploadBloat: 180)
        reference.crossValidation = [Fixture.check("b", median: 14, loss: 7), Fixture.check("c", median: 60, loss: 9)]
        reference.protocolProbe = protocolProbe(proto: .http1_1, quic: [
            QUICProbeOutcome(host: "a", handshakeMs: nil, failure: .timeout, detail: nil, tcpReachable: true)])
        var wifi = Fixture.result(.wifi, download: 300, upload: 40, uploadBloat: 150)
        wifi.interfaceCompare = [InterfaceProbeResult(interface: .cellular, tcpConnect: nil, error: "未連線")]
        wifi.mtu = MTUResult(date: Date(), target: "1.1.1.1", pathMTU: 1500, probes: [], method: "t")
        let lte = Fixture.result(.lte, download: 80, upload: 20)
        return [Fixture.session([reference]), Fixture.session([wifi]), Fixture.session([reference, wifi, lte]),
                Fixture.session([lte]), DiagnosticSession(title: "empty")]
    }

    func testAllScenarioReportsAreConsistent() {
        for (i, session) in scenarios().enumerated() {
            let r = report(session)
            XCTAssertEqual(ReportConsistencyValidator.validate(r), [], "scenario \(i)")
            XCTAssertTrue(generator.text(r).contains("14. Consistency check\npassed"), "scenario \(i)")
        }
    }

    func testStatisticsMatchPrintedWindows() {
        let r = report(scenarios()[0])
        let text = generator.text(r)
        let summary = r.rawTests[0].result.download!.summary   // first "statistics windows" line is the download
        let line = text.split(separator: "\n").first { $0.contains("statistics windows") }!
        let values = line.split(separator: ":").last!.split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(values.count, summary.analysisWindowCount)
        XCTAssertEqual(Percentile.value(0.5, in: values)!, summary.medianMbps, accuracy: 0.06, "printed windows reproduce the median")
        XCTAssertGreaterThan(summary.medianMbps, 0)
        XCTAssertTrue(text.contains("NOT the statistics basis"), "bucket aggregation is labelled explicitly")
    }

    func testProtocolStatementMatchesNegotiatedProtocol() {
        var r = Fixture.result(.wifi)
        r.server = ServerDescriptor.builtIn[0]
        r.protocolProbe = protocolProbe(proto: .http1_1, quic: ["a", "b"].map {
            QUICProbeOutcome(host: $0, handshakeMs: nil, failure: .timeout, detail: nil, tcpReachable: true) })
        let set = EvidenceExtractor().extract(from: Fixture.session([r]))
        let quic = set.evidence.first { $0.code == .quicBlocked }
        XCTAssertNotNil(quic)
        XCTAssertTrue(quic!.statement.contains("HTTP/1.1"))
        XCTAssertFalse(set.evidence.contains { $0.statement.contains("HTTP/2") })
    }

    func testSingleQUICFailureDoesNotClaimBlocking() {
        let r = report(scenarios()[0])
        XCTAssertFalse(r.analysis.evidence.codes.contains(.quicBlocked))
        XCTAssertTrue(r.analysis.evidence.codes.contains(.quicEndpointFailure))
        XCTAssertNotEqual(r.analysis.hypotheses.first { $0.cause == .udpQuicBlocked }?.likelihood, .likely)
    }

    func testMTUNormalIsNotGlobalRuledOut() {
        let r = report(scenarios()[1])
        let mtu = r.analysis.hypotheses.first { $0.cause == .mtuTunnelIssue }!
        XCTAssertNotEqual(mtu.likelihood, .ruledOut)
        XCTAssertTrue(r.analysis.evidence.evidence.first { $0.code == .mtuNormal }!.statement.contains("noIssueObservedOnTestedPath"))
    }

    func testUnavailableInterfaceIsListedAsNotTested() {
        let r = report(scenarios()[1])
        XCTAssertTrue(r.analysis.evidence.codes.contains(.interfaceProbeUnavailable))
        XCTAssertFalse(r.analysis.evidence.codes.contains(.allInterfacesDegraded))
        XCTAssertTrue(generator.text(r).contains("NOT TESTED / unavailable"))
    }

    func testValidatorCatchesContradictions() {
        var r = report(scenarios()[0])
        // Inject: rule out a hypothesis without decisive evidence, and claim HTTP/2 on an HTTP/1.1 test.
        if let i = r.analysis.hypotheses.firstIndex(where: { $0.likelihood == .notTested }) {
            r.analysis.hypotheses[i].likelihood = .ruledOut
        }
        let testID = r.rawTests[0].id
        r.analysis.evidence.evidence.append(DiagnosticEvidence(code: .quicBlocked, statement: "QUIC 失敗，HTTP/2 正常", testIDs: [testID]))
        let issues = ReportConsistencyValidator.validate(r)
        XCTAssertTrue(issues.contains { $0.contains("ruled out without decisive evidence") })
        XCTAssertTrue(issues.contains { $0.contains("claims HTTP/2") })
    }
}
