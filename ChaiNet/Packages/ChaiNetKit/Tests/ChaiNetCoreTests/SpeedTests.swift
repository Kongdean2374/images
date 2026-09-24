import XCTest
@testable import ChaiNetCore

final class SpeedCalculationTests: XCTestCase {
    func testMbpsConversion() {
        // 12.5 MB in 1 s = 100 Mbps
        XCTAssertEqual(SpeedMath.mbps(bytes: 12_500_000, seconds: 1), 100, accuracy: 1e-9)
        XCTAssertEqual(SpeedMath.mbps(bytes: 1_000_000, seconds: 0.5), 16, accuracy: 1e-9)
        XCTAssertEqual(SpeedMath.mbps(bytes: 100, seconds: 0), 0)
    }

    /// Builds 100 ms samples with the given Mbps values.
    func timeline(_ mbps: [Double], interval: Double = 0.1) -> [SpeedSample] {
        var cumulative: Int64 = 0
        return mbps.enumerated().map { i, rate in
            let bytes = Int64(rate * 1_000_000 / 8 * interval)
            cumulative += bytes
            return SpeedSample(offset: Double(i + 1) * interval, intervalDuration: interval, intervalBytes: bytes,
                               cumulativeBytes: cumulative, activeStreams: 4)
        }
    }

    func testWarmupExcludedFromStatistics() {
        // 10 warm-up samples (≤ 1.0 s) at 10 Mbps, then 20 at 100 Mbps.
        let samples = timeline(Array(repeating: 10, count: 10) + Array(repeating: 100, count: 20))
        let s = SpeedCalculator.summarize(samples: samples, warmupDuration: 1.0)
        XCTAssertEqual(s.warmupSampleCount, 10)
        XCTAssertEqual(s.averageMbps, 100, accuracy: 0.01)
        XCTAssertEqual(s.minimumMbps, 100, accuracy: 0.01)
        XCTAssertEqual(s.stability.score!, 100, accuracy: 0.01)
        XCTAssertEqual(s.totalBytes, samples.last!.cumulativeBytes)
    }

    func testAveragePeakMinimumP95PerSample() {
        let rates: [Double] = [50, 60, 70, 80, 90, 100, 110, 120, 130, 140]
        let s = SpeedCalculator.summarize(samples: timeline(rates), warmupDuration: 0, windowSamples: 1)
        XCTAssertEqual(s.averageMbps, 95, accuracy: 0.01, "time-weighted average of equal intervals = mean")
        XCTAssertEqual(s.minimumMbps, 50, accuracy: 0.01)
        XCTAssertEqual(s.peakMbps, 140, accuracy: 0.01)
        XCTAssertEqual(s.p95Mbps, Percentile.value(0.95, in: rates)!, accuracy: 0.01)
        XCTAssertEqual(s.p10Mbps, Percentile.value(0.10, in: rates)!, accuracy: 0.01)
    }

    func testWindowedStatistics() {
        // 10 samples → two 0.5 s windows: mean(50…90) = 70, mean(100…140) = 120
        let rates: [Double] = [50, 60, 70, 80, 90, 100, 110, 120, 130, 140]
        let s = SpeedCalculator.summarize(samples: timeline(rates), warmupDuration: 0)
        XCTAssertEqual(s.analysisWindowMbps!.count, 2)
        XCTAssertEqual(s.minimumMbps, 70, accuracy: 0.01)
        XCTAssertEqual(s.peakMbps, 120, accuracy: 0.01)
        XCTAssertEqual(s.medianMbps, 95, accuracy: 0.01)
        XCTAssertEqual(s.medianMbps, Percentile.value(0.5, in: s.analysisWindowMbps!)!, accuracy: 1e-9,
                       "reported median must be reproducible from the reported windows")
    }

    func testPeakRejectsSingleSpike() {
        let rates: [Double] = [100, 100, 900, 100, 100]
        let s = SpeedCalculator.summarize(samples: timeline(rates), warmupDuration: 0, windowSamples: 3)
        XCTAssertEqual(s.peakMbps, 1100.0 / 3, accuracy: 0.01)
        XCTAssertLessThan(s.peakMbps, 900)
    }

    func testBurstyUploadMedianIsNotZero() {
        // Upload progress arrives in bursts: 0, 0, 0, 250 Mbps … per 100 ms. The link carries ~62 Mbps.
        let rates: [Double] = (0..<40).map { $0 % 4 == 3 ? 250 : 0 }
        let s = SpeedCalculator.summarize(samples: timeline(rates), warmupDuration: 0, windowSamples: 4)
        XCTAssertEqual(s.medianMbps, 62.5, accuracy: 0.5)
        XCTAssertGreaterThan(s.stability.score!, 90, "bursts inside a window are not instability")
    }

    func testAdaptiveWindowAbsorbsUploadBatching() {
        // Same 0,0,0,250 pattern without forcing a window: detector widens to 2 × (3 + 1) = 8 samples.
        let rates: [Double] = (0..<80).map { $0 % 4 == 3 ? 250 : 0 }
        let s = SpeedCalculator.summarize(samples: timeline(rates), warmupDuration: 0)
        XCTAssertEqual(s.samplingArtifactDetected, true)
        XCTAssertEqual(s.windowSamples, 8)
        XCTAssertEqual(s.zeroIntervalFraction!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(s.medianMbps, 62.5, accuracy: 0.5)
        XCTAssertEqual(s.minimumMbps, 62.5, accuracy: 0.5, "no false 0 Mbps window")
        XCTAssertLessThan(s.peakMbps, 70, "no false 1000+ Mbps peak")
        // Artifact-contaminated timeline: short-window stability is not computed (measurement
        // limitation), and never reported as instability. The byte-count average stays valid.
        XCTAssertNil(s.stability.score)
        XCTAssertNil(s.reliableStabilityScore)
        XCTAssertNil(s.reliableP10Mbps)
        XCTAssertNil(s.reliableMinimumMbps)
        XCTAssertEqual(s.stabilityUnavailableReason, "measurementSamplingArtifact")
        XCTAssertEqual(s.sustainedMbps, s.averageMbps, accuracy: 1e-9)
        XCTAssertEqual(s.averageMbps, 62.5, accuracy: 0.5)
    }

    func testRealOutageIsNotSmoothedAway() {
        // 3 s at 100 Mbps, a 2 s genuine stall, 3 s at 100 Mbps → one zero run is an outage, not batching.
        let rates = Array(repeating: 100.0, count: 30) + Array(repeating: 0.0, count: 20) + Array(repeating: 100.0, count: 30)
        let s = SpeedCalculator.summarize(samples: timeline(rates), warmupDuration: 0)
        XCTAssertEqual(s.samplingArtifactDetected, false)
        XCTAssertEqual(s.windowSamples, SpeedCalculator.defaultWindowSamples)
        XCTAssertEqual(s.minimumMbps, 0, accuracy: 0.01, "the real dip must remain in the statistics")
        XCTAssertLessThan(s.stability.score!, 80)
    }

    func testStreamTransitionsExcluded() {
        // Ramp dip right after streams go 2 → 8 at t = 2 s must not count as instability.
        var rates = Array(repeating: 100.0, count: 60)
        for i in 20..<30 { rates[i] = 20 }   // 2.0–3.0 s: new streams ramping
        let changes = [StreamChange(offset: 0, streams: 2), StreamChange(offset: 2.0, streams: 8)]
        let s = SpeedCalculator.summarize(samples: timeline(rates), streamChanges: changes, warmupDuration: 1)
        XCTAssertEqual(s.transitionExcludedSampleCount, 10)
        XCTAssertEqual(s.minimumMbps, 100, accuracy: 0.01)
        XCTAssertEqual(s.stability.score!, 100, accuracy: 0.01)
        let naive = SpeedCalculator.summarize(samples: timeline(rates), warmupDuration: 1)
        XCTAssertLessThan(naive.stability.score!, 90)
    }

    func testTimeWeightedAverageWithUnevenIntervals() {
        // 1 MB in 0.1 s (80 Mbps) and 1 MB in 0.9 s (8.9 Mbps): average must be 2 MB / 1 s = 16 Mbps.
        let a = SpeedSample(offset: 0.1, intervalDuration: 0.1, intervalBytes: 1_000_000, cumulativeBytes: 1_000_000, activeStreams: 2)
        let b = SpeedSample(offset: 1.0, intervalDuration: 0.9, intervalBytes: 1_000_000, cumulativeBytes: 2_000_000, activeStreams: 2)
        let s = SpeedCalculator.summarize(samples: [a, b], warmupDuration: 0)
        XCTAssertEqual(s.averageMbps, 16, accuracy: 1e-6)
    }

    func testEmptyTimeline() {
        let s = SpeedCalculator.summarize(samples: [])
        XCTAssertEqual(s.averageMbps, 0)
        XCTAssertNil(s.stability.score)
    }
}

final class StabilityTests: XCTestCase {
    func testPerfectlyStable() {
        let m = StabilityCalculator.evaluate([50, 50, 50, 50])
        XCTAssertEqual(m.coefficientOfVariation!, 0, accuracy: 1e-12)
        XCTAssertEqual(m.score!, 100, accuracy: 1e-9)
        XCTAssertEqual(m.dropCount, 0)
    }

    func testScoreFromCV() {
        // CV = 0.4 → score 60
        let m = StabilityCalculator.evaluate([2, 4, 4, 4, 5, 5, 7, 9])
        XCTAssertEqual(m.score!, 60, accuracy: 1e-9)
    }

    func testDropsBelowHalfMedian() {
        // median 100 → threshold 50 → two drops (10, 40)
        let m = StabilityCalculator.evaluate([100, 100, 10, 100, 40, 100, 100])
        XCTAssertEqual(m.dropCount, 2)
    }

    func testChaoticSeriesClampsToZero() {
        let m = StabilityCalculator.evaluate([0, 0, 0, 0, 100])
        XCTAssertEqual(m.score, 0)
    }
}

final class StreamScalingPolicyTests: XCTestCase {
    let policy = StreamScalingPolicy.default

    func testTiers() {
        XCTAssertEqual(policy.initialStreams, 2)
        XCTAssertEqual(policy.recommendedStreams(forMbps: 10), 2)
        XCTAssertEqual(policy.recommendedStreams(forMbps: 25), 4)
        XCTAssertEqual(policy.recommendedStreams(forMbps: 99), 4)
        XCTAssertEqual(policy.recommendedStreams(forMbps: 250), 8)
        XCTAssertEqual(policy.recommendedStreams(forMbps: 950), 16)
    }

    func testNeverScalesDown() {
        XCTAssertEqual(policy.nextStreamCount(current: 8, measuredMbps: 5), 8)
        XCTAssertEqual(policy.nextStreamCount(current: 2, measuredMbps: 500), 16)
    }

    func testOnlyAllowedCounts() {
        for mbps in stride(from: 0.0, through: 2000, by: 7.5) {
            XCTAssertTrue(StreamScalingPolicy.allowedStreamCounts.contains(policy.recommendedStreams(forMbps: mbps)))
        }
    }
}

final class BufferbloatTests: XCTestCase {
    func stats(_ rtts: [Double]) -> LatencyStatistics {
        LatencyStatistics.compute(from: rtts.enumerated().map { LatencySample(sequence: $0.offset, offset: 0, rttMs: $0.element) })
    }

    func testGrades() {
        XCTAssertEqual(BufferbloatGrade.from(increaseMs: 2), .aPlus)
        XCTAssertEqual(BufferbloatGrade.from(increaseMs: 29), .a)
        XCTAssertEqual(BufferbloatGrade.from(increaseMs: 30), .b)
        XCTAssertEqual(BufferbloatGrade.from(increaseMs: 150), .c)
        XCTAssertEqual(BufferbloatGrade.from(increaseMs: 399), .d)
        XCTAssertEqual(BufferbloatGrade.from(increaseMs: 800), .f)
        XCTAssertLessThan(BufferbloatGrade.aPlus, BufferbloatGrade.f)
    }

    func testCompareIdleAndLoaded() {
        let r = BufferbloatCalculator.evaluate(idle: stats([20, 20, 20]), downloadLoaded: stats([60, 60, 60]), uploadLoaded: stats([250, 250, 250]))!
        XCTAssertEqual(r.downloadIncreaseMs, 40)
        XCTAssertEqual(r.uploadIncreaseMs, 230)
        XCTAssertEqual(r.downloadGrade, .b)
        XCTAssertEqual(r.uploadGrade, .d)
        XCTAssertEqual(r.grade, .d, "overall = worst direction")
    }

    func testNegativeIncreaseClampedToZero() {
        let r = BufferbloatCalculator.evaluate(idle: stats([30]), downloadLoaded: stats([25]), uploadLoaded: nil)!
        XCTAssertEqual(r.downloadIncreaseMs, 0)
        XCTAssertNil(r.uploadIncreaseMs)
        XCTAssertEqual(r.grade, .aPlus)
    }

    func testRequiresLoadedData() {
        XCTAssertNil(BufferbloatCalculator.evaluate(idle: stats([20]), downloadLoaded: nil, uploadLoaded: nil))
    }
}

final class EventDetectorTests: XCTestCase {
    func testSpikeDetection() {
        var d = LatencySpikeDetector(windowSize: 20, madMultiplier: 5, minimumIncreaseMs: 30, minimumBaselineSamples: 5)
        for i in 0..<10 { XCTAssertNil(d.ingest(sequence: i, offset: Double(i), rttMs: 20 + Double(i % 2))) }
        XCTAssertNil(d.ingest(sequence: 10, offset: 10, rttMs: 45), "within floor of 30 ms")
        let spike = d.ingest(sequence: 11, offset: 11, rttMs: 200)
        XCTAssertNotNil(spike)
        XCTAssertEqual(spike?.rttMs, 200)
    }

    func testNoDecisionBeforeBaseline() {
        var d = LatencySpikeDetector(minimumBaselineSamples: 5)
        XCTAssertNil(d.ingest(sequence: 0, offset: 0, rttMs: 10))
        XCTAssertNil(d.ingest(sequence: 1, offset: 1, rttMs: 900))
    }

    func testDropDetection() {
        var d = NetworkDropDetector(consecutiveLossThreshold: 3)
        func s(_ i: Int, _ rtt: Double?) -> LatencySample { LatencySample(sequence: i, offset: Double(i), rttMs: rtt) }
        XCTAssertNil(d.ingest(s(0, 10)))
        XCTAssertNil(d.ingest(s(1, nil)))
        XCTAssertNil(d.ingest(s(2, nil)))
        guard case .started(let started)? = d.ingest(s(3, nil)) else { return XCTFail("drop should start") }
        XCTAssertEqual(started.startOffset, 1)
        XCTAssertNil(d.ingest(s(4, nil)))
        guard case .ended(let ended)? = d.ingest(s(5, 12)) else { return XCTFail("drop should end") }
        XCTAssertEqual(ended.lostProbes, 4)
        XCTAssertEqual(ended.duration, 4)
    }

    func testShortLossIsNotADrop() {
        var d = NetworkDropDetector(consecutiveLossThreshold: 3)
        XCTAssertNil(d.ingest(LatencySample(sequence: 0, offset: 0, rttMs: nil)))
        XCTAssertNil(d.ingest(LatencySample(sequence: 1, offset: 1, rttMs: nil)))
        XCTAssertNil(d.ingest(LatencySample(sequence: 2, offset: 2, rttMs: 10)))
        XCTAssertFalse(d.isInDrop)
    }
}
