import XCTest
@testable import ChaiNetCore

final class VoiceQualityTests: XCTestCase {
    func testRFactorBelow160() {
        // EL = 20 + 2·5 + 10 = 40 → R = 93.2 − 1 − 2.5·1 = 89.7
        XCTAssertEqual(VoiceQualityCalculator.rFactor(averageLatencyMs: 20, jitterMs: 5, lossPercent: 1), 89.7, accuracy: 1e-9)
    }

    func testRFactorAbove160() {
        // EL = 200 + 0 + 10 = 210 → R = 93.2 − (210 − 120)/10 = 84.2
        XCTAssertEqual(VoiceQualityCalculator.rFactor(averageLatencyMs: 200, jitterMs: 0, lossPercent: 0), 84.2, accuracy: 1e-9)
    }

    func testRFactorClamped() {
        XCTAssertEqual(VoiceQualityCalculator.rFactor(averageLatencyMs: 2000, jitterMs: 500, lossPercent: 50), 0)
    }

    func testMOS() {
        XCTAssertEqual(VoiceQualityCalculator.mos(rFactor: 0), 1)
        XCTAssertEqual(VoiceQualityCalculator.mos(rFactor: 100), 4.5)
        // R = 93.2: 1 + 3.262 + 7e-6·93.2·33.2·6.8
        let expected = 1 + 0.035 * 93.2 + 0.000007 * 93.2 * 33.2 * 6.8
        XCTAssertEqual(VoiceQualityCalculator.mos(rFactor: 93.2), expected, accuracy: 1e-9)
        XCTAssertEqual(VoiceRating.from(rFactor: 93.2), .excellent)
        XCTAssertEqual(VoiceRating.from(rFactor: 65), .poor)
    }
}

final class GamingQualityTests: XCTestCase {
    func testVerdictRatios() {
        let fps = GamingQualityCalculator.verdict(for: .competitiveShooter, latencyP95: 40, jitter: 5, lossPercent: 0, downloadMbps: 100)
        XCTAssertEqual(fps.verdict, .great)
        XCTAssertTrue(fps.limitingFactors.isEmpty)

        let laggy = GamingQualityCalculator.verdict(for: .competitiveShooter, latencyP95: 70, jitter: 5, lossPercent: 0, downloadMbps: nil)
        XCTAssertEqual(laggy.verdict, .playable, "70/50 = 1.4")
        XCTAssertEqual(laggy.limitingFactors, ["延遲"])

        let lossy = GamingQualityCalculator.verdict(for: .moba, latencyP95: 30, jitter: 5, lossPercent: 3, downloadMbps: nil)
        XCTAssertEqual(lossy.verdict, .unsuitable, "3/1 = 3 > 2.5")
    }

    func testUsesLoadedLatencyWhenAvailable() {
        func stats(_ v: Double) -> LatencyStatistics {
            LatencyStatistics.compute(from: (0..<10).map { LatencySample(sequence: $0, offset: 0, rttMs: v) })
        }
        let r = GamingQualityCalculator.evaluate(idle: stats(20), loaded: stats(300), spikes: [], packetsPerSecond: 50, downloadMbps: 100, score: nil)
        XCTAssertEqual(r.verdicts.first { $0.genre == .competitiveShooter }?.verdict, .unsuitable)
    }
}

final class StreamingAndOBSTests: XCTestCase {
    func speed(_ direction: TransferDirection, rates: [Double]) -> SpeedResult {
        var cumulative: Int64 = 0
        let samples = rates.enumerated().map { i, r -> SpeedSample in
            let b = Int64(r * 1_000_000 / 8 * 0.1); cumulative += b
            return SpeedSample(offset: Double(i + 1) * 0.1, intervalDuration: 0.1, intervalBytes: b, cumulativeBytes: cumulative, activeStreams: 2)
        }
        return SpeedResult(direction: direction, samples: samples, summary: SpeedCalculator.summarize(samples: samples, warmupDuration: 0),
                           streamChanges: [], wasCancelled: false)
    }

    func testStreamingTiers() {
        let r = StreamingQualityCalculator.evaluate(download: speed(.download, rates: Array(repeating: 12, count: 20)), ttfbMs: 50, score: nil)
        XCTAssertEqual(r.sustainedMbps, 12, accuracy: 0.01)
        // 1080p needs 8 × 1.25 = 10 ≤ 12 ✓ ; 1440p needs 20 ✗
        XCTAssertEqual(r.maxSupportedTier?.name, "1080p Full HD")
        // startup = 50 + 2 × 8 / 12 × 1000
        XCTAssertEqual(r.estimatedStartupMs!, 50 + 2 * 8 / 12 * 1000, accuracy: 1)
    }

    func testOBSRecommendation() {
        let r = OBSSuitabilityCalculator.evaluate(upload: speed(.upload, rates: Array(repeating: 10, count: 20)),
                                                  idleLatency: nil, uploadLoadedLatency: nil, score: nil)
        XCTAssertEqual(r.recommendedBitrateKbps, 7500, accuracy: 1)
        // 1080p60 = 6160 / 10000 = 0.616 → playable
        XCTAssertEqual(r.presets.first { $0.preset.name == "1080p60" }?.verdict, .playable)
        XCTAssertEqual(r.presets.first { $0.preset.name == "720p30" }?.verdict, .great)
        XCTAssertEqual(r.presets.first { $0.preset.name == "4K60 (YouTube)" }?.verdict, .unsuitable)
    }

    func testOBSDowngradeWhenUnstable() {
        var rates: [Double] = []
        for i in 0..<20 { rates.append(i % 2 == 0 ? 20 : 2) }
        let r = OBSSuitabilityCalculator.evaluate(upload: speed(.upload, rates: rates), idleLatency: nil, uploadLoadedLatency: nil, score: nil)
        XCTAssertFalse(r.warnings.isEmpty)
        XCTAssertFalse(r.presets.contains { $0.verdict == .great })
    }
}
