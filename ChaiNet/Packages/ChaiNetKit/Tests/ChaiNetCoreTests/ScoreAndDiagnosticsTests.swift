import XCTest
@testable import ChaiNetCore

final class ScoreCurveTests: XCTestCase {
    func testInterpolation() {
        let c = ScoreCurve([(0, 0), (10, 100)])
        XCTAssertEqual(c.score(5), 50)
        XCTAssertEqual(c.score(-1), 0)
        XCTAssertEqual(c.score(20), 100)
    }

    func testStandardCurvePoints() {
        XCTAssertEqual(ScoreCurve.download.score(100), 85)
        XCTAssertEqual(ScoreCurve.loss.score(5), 15)
        XCTAssertEqual(ScoreCurve.latency.score(10), 100)
        XCTAssertEqual(ScoreCurve.jitter.score(15), 70)
        XCTAssertEqual(ScoreCurve.loss.score(1.75), 52.5, accuracy: 1e-9)
    }
}

final class ScoreEngineTests: XCTestCase {
    let engine = ScoreEngine()

    func excellent() -> MetricSnapshot {
        var m = MetricSnapshot()
        m.downloadMbps = 1000; m.uploadMbps = 500; m.idleLatencyMs = 5; m.jitterMs = 1; m.lossPercent = 0
        m.downloadBloatMs = 2; m.uploadBloatMs = 2; m.downloadStability = 100; m.uploadStability = 100
        return m
    }

    func testExcellentConnectionScores100() {
        let s = engine.scores(for: excellent())
        XCTAssertEqual(s.overall, 100)
        XCTAssertEqual(s.gaming, 100)
        XCTAssertEqual(s.streaming, 100)
        XCTAssertEqual(s.voice, 100)
        XCTAssertEqual(s.upload, 100)
    }

    func testScenarioWeightsDiffer() {
        // Fast but laggy link: great for streaming, bad for gaming.
        var m = excellent()
        m.idleLatencyMs = 140; m.jitterMs = 40
        let s = engine.scores(for: m)
        XCTAssertGreaterThan(s.streaming!, 85)
        XCTAssertLessThan(s.gaming!, 60)
        XCTAssertGreaterThan(s.streaming!, s.gaming!)
    }

    func testWeightedAverageMath() {
        // Upload profile: upload .45, uploadStability .25, uploadBloat .15, loss .15
        var m = MetricSnapshot()
        m.uploadMbps = 20      // curve → 80
        m.uploadStability = 60 // identity → 60
        m.uploadBloatMs = 30   // curve → 85
        m.lossPercent = 0.5    // curve → 80
        let expected = (0.45 * 80 + 0.25 * 60 + 0.15 * 85 + 0.15 * 80) / 1.0
        XCTAssertEqual(engine.score(m, profile: .upload), Int(expected.rounded()))
    }

    func testRenormalisesOverMeasuredMetrics() {
        var m = MetricSnapshot()
        m.uploadMbps = 20          // 80, weight .45
        m.uploadStability = 60     // 60, weight .25
        // coverage .70 ≥ .5 → (0.45·80 + 0.25·60) / 0.70
        XCTAssertEqual(engine.score(m, profile: .upload), Int(((0.45 * 80 + 0.25 * 60) / 0.70).rounded()))
    }

    func testInsufficientCoverageYieldsNil() {
        var m = MetricSnapshot()
        m.downloadMbps = 100 // gaming weight .05 only
        XCTAssertNil(engine.score(m, profile: .gaming))
    }

    func testLossCapsGaming() {
        var m = excellent()
        m.lossPercent = 6
        let s = engine.scores(for: m)
        XCTAssertLessThanOrEqual(s.gaming!, 25)
        XCTAssertLessThanOrEqual(s.voice!, 25)
        XCTAssertLessThanOrEqual(s.overall!, 40)
    }

    func testLowUploadCapsUploadScore() {
        var m = excellent()
        m.uploadMbps = 2
        XCTAssertLessThanOrEqual(engine.scores(for: m).upload!, 30)
    }

    func testScoresInRange() {
        var m = MetricSnapshot()
        m.downloadMbps = 0; m.uploadMbps = 0; m.idleLatencyMs = 5000; m.jitterMs = 5000; m.lossPercent = 100
        m.downloadBloatMs = 9999; m.uploadBloatMs = 9999; m.downloadStability = 0; m.uploadStability = 0
        let s = engine.scores(for: m)
        for v in [s.overall, s.gaming, s.streaming, s.voice, s.upload] {
            XCTAssertEqual(v, 0)
        }
    }
}

final class DiagnosticsEngineTests: XCTestCase {
    let engine = DiagnosticsEngine()

    func codes(_ m: MetricSnapshot) -> Set<DiagnosticCode> { Set(engine.diagnose(m).map(\.code)) }

    func testUplinkCongestion() {
        var m = MetricSnapshot()
        m.downloadMbps = 300; m.uploadMbps = 2
        XCTAssertTrue(codes(m).contains(.uplinkCongestion))
        XCTAssertFalse(codes(m).contains(.asymmetricLink), "congestion supersedes asymmetric info")
        m.uploadMbps = 3
        XCTAssertFalse(codes(m).contains(.uplinkCongestion), "boundary: upload must be < 3")
        m.downloadMbps = 100; m.uploadMbps = 1
        XCTAssertFalse(codes(m).contains(.uplinkCongestion), "boundary: download must be > 100")
    }

    func testLowLatencyHighJitter() {
        var m = MetricSnapshot()
        m.idleLatencyMs = 20; m.jitterMs = 90
        let findings = engine.diagnose(m)
        let f = findings.first { $0.code == .lowLatencyHighJitter }
        XCTAssertEqual(f?.severity, .critical)
        XCTAssertFalse(findings.contains { $0.code == .highJitter }, "specific finding suppresses generic one")
        m.idleLatencyMs = 30
        XCTAssertFalse(codes(m).contains(.lowLatencyHighJitter))
        XCTAssertTrue(codes(m).contains(.highJitter))
    }

    func testPacketLossSeverity() {
        var m = MetricSnapshot()
        m.lossPercent = 6
        let f = engine.diagnose(m).first { $0.code == .severePacketLoss }
        XCTAssertEqual(f?.severity, .critical)
        XCTAssertFalse(codes(m).contains(.moderatePacketLoss))
        m.lossPercent = 5
        XCTAssertFalse(codes(m).contains(.severePacketLoss), "boundary: > 5 %")
        XCTAssertTrue(codes(m).contains(.moderatePacketLoss))
    }

    func testBurstLoss() {
        var m = MetricSnapshot()
        m.lossPercent = 2; m.lossPattern = .burst; m.burstLossPercent = 2
        XCTAssertTrue(codes(m).contains(.burstLoss))
        m.lossPattern = .random
        XCTAssertFalse(codes(m).contains(.burstLoss))
    }

    func testBufferbloatSeverity() {
        var m = MetricSnapshot()
        m.downloadBloatMs = 150; m.uploadBloatMs = 350
        let f = engine.diagnose(m)
        XCTAssertEqual(f.first { $0.code == .downloadBufferbloat }?.severity, .warning)
        XCTAssertEqual(f.first { $0.code == .uploadBufferbloat }?.severity, .critical)
    }

    func testSortedBySeverity() {
        var m = MetricSnapshot()
        m.lossPercent = 10; m.isExpensive = true; m.downloadBloatMs = 150
        let severities = engine.diagnose(m).map(\.severity)
        XCTAssertEqual(severities, severities.sorted(by: >))
    }

    func testHealthy() {
        var m = MetricSnapshot()
        m.downloadMbps = 500; m.uploadMbps = 100; m.idleLatencyMs = 10; m.jitterMs = 2; m.lossPercent = 0
        XCTAssertEqual(engine.diagnose(m).map(\.code), [.healthy])
    }

    func testNoDataNoFindings() {
        XCTAssertTrue(engine.diagnose(MetricSnapshot()).isEmpty)
    }

    func testSingleRuleIsolation() {
        let single = DiagnosticsEngine(rules: [DiagnosticRules.networkDrops])
        var m = MetricSnapshot()
        m.dropCount = 2
        XCTAssertEqual(single.diagnose(m).first?.code, .networkDrops)
    }
}
