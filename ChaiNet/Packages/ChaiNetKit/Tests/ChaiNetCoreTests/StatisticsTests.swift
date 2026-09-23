import XCTest
@testable import ChaiNetCore

final class PercentileTests: XCTestCase {
    func testEmptyReturnsNil() {
        XCTAssertNil(Percentile.value(0.5, in: []))
    }

    func testSingleValue() {
        XCTAssertEqual(Percentile.value(0.95, in: [42]), 42)
    }

    func testType7LinearInterpolation() {
        // 1…10: h = 9 × 0.95 = 8.55 → 9 + 0.55 × (10 − 9) = 9.55 (matches numpy.percentile)
        let values = (1...10).map(Double.init)
        XCTAssertEqual(Percentile.value(0.95, in: values)!, 9.55, accuracy: 1e-9)
        XCTAssertEqual(Percentile.value(0.99, in: values)!, 9.91, accuracy: 1e-9)
        XCTAssertEqual(Percentile.value(0.5, in: values)!, 5.5, accuracy: 1e-9)
        XCTAssertEqual(Percentile.value(0.10, in: values)!, 1.9, accuracy: 1e-9)
    }

    func testBoundsAreMinAndMax() {
        let values = [7.0, 3, 9, 1]
        XCTAssertEqual(Percentile.value(0, in: values), 1)
        XCTAssertEqual(Percentile.value(1, in: values), 9)
        XCTAssertEqual(Percentile.value(-1, in: values), 1, "p is clamped")
        XCTAssertEqual(Percentile.value(2, in: values), 9, "p is clamped")
    }

    func testUnsortedInputIsSorted() {
        XCTAssertEqual(Percentile.value(0.5, in: [5, 1, 3])!, 3)
    }
}

final class DescriptiveTests: XCTestCase {
    func testMeanMedian() {
        XCTAssertEqual(Descriptive.mean([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(Descriptive.median([1, 2, 3, 4]), 2.5)
        XCTAssertNil(Descriptive.mean([]))
    }

    func testStandardDeviations() {
        // Classic example: population σ = 2, sample s = √(32/7)
        let v = [2.0, 4, 4, 4, 5, 5, 7, 9]
        XCTAssertEqual(Descriptive.populationStandardDeviation(v)!, 2, accuracy: 1e-12)
        XCTAssertEqual(Descriptive.sampleStandardDeviation(v)!, (32.0 / 7).squareRoot(), accuracy: 1e-12)
        XCTAssertNil(Descriptive.sampleStandardDeviation([1]))
    }

    func testCoefficientOfVariation() {
        XCTAssertEqual(Descriptive.coefficientOfVariation([2, 4, 4, 4, 5, 5, 7, 9])!, 0.4, accuracy: 1e-12)
        XCTAssertNil(Descriptive.coefficientOfVariation([0, 0]))
    }

    func testMAD() {
        // median = 2; |x − 2| = 1,1,0,0,2,4,7 → median 1
        XCTAssertEqual(Descriptive.medianAbsoluteDeviation([1, 1, 2, 2, 4, 6, 9]), 1)
    }

    func testMovingAverage() {
        XCTAssertEqual(Descriptive.movingAverage([1, 2, 3, 4, 5], window: 3), [2, 3, 4])
        XCTAssertEqual(Descriptive.movingAverage([1, 2], window: 3), [])
    }
}

final class JitterTests: XCTestCase {
    func testMeanConsecutiveDifference() {
        // |12−10| + |11−12| + |15−11| = 2 + 1 + 4 = 7 → 7 / 3
        XCTAssertEqual(Jitter.meanConsecutiveDifference([10, 12, 11, 15])!, 7.0 / 3, accuracy: 1e-12)
    }

    func testConstantSeriesHasZeroJitter() {
        XCTAssertEqual(Jitter.meanConsecutiveDifference([20, 20, 20]), 0)
        XCTAssertEqual(Jitter.rfc3550([20, 20, 20]), 0)
    }

    func testTooFewSamples() {
        XCTAssertNil(Jitter.meanConsecutiveDifference([5]))
        XCTAssertNil(Jitter.rfc3550([]))
    }

    func testRFC3550Smoothing() {
        // J1 = 0 + (16 − 0)/16 = 1 ; J2 = 1 + (16 − 1)/16 = 1.9375
        XCTAssertEqual(Jitter.rfc3550([0, 16, 0])!, 1.9375, accuracy: 1e-12)
    }
}

final class PacketLossTests: XCTestCase {
    func testNoLoss() {
        let a = PacketLossAnalyzer.analyze(received: Array(repeating: true, count: 10))
        XCTAssertEqual(a.lost, 0)
        XCTAssertEqual(a.lossPercent, 0)
        XCTAssertEqual(a.pattern, .none)
    }

    func testRandomLoss() {
        // T F T T F T T T F T → 3 isolated losses
        let seq = [true, false, true, true, false, true, true, true, false, true]
        let a = PacketLossAnalyzer.analyze(received: seq)
        XCTAssertEqual(a.lost, 3)
        XCTAssertEqual(a.lossPercent, 30, accuracy: 1e-9)
        XCTAssertEqual(a.randomLossEvents, 3)
        XCTAssertEqual(a.burstEvents, 0)
        XCTAssertEqual(a.randomLossPercent, 30, accuracy: 1e-9)
        XCTAssertEqual(a.burstLossPercent, 0)
        XCTAssertEqual(a.longestBurst, 1)
        XCTAssertEqual(a.pattern, .random)
    }

    func testBurstLoss() {
        // T T F F F F T T T T → one burst of 4
        let seq = [true, true, false, false, false, false, true, true, true, true]
        let a = PacketLossAnalyzer.analyze(received: seq)
        XCTAssertEqual(a.burstEvents, 1)
        XCTAssertEqual(a.packetsLostInBursts, 4)
        XCTAssertEqual(a.longestBurst, 4)
        XCTAssertEqual(a.burstLossPercent, 40, accuracy: 1e-9)
        XCTAssertEqual(a.pattern, .burst)
        // Gilbert: received with successor = 6 (idx 0,1,6,7,8 + … ) → transitions T→F once
        // received indices with successor: 0,1,6,7,8 = 5 → p = 1/5
        XCTAssertEqual(a.lossProbabilityAfterReceive, 0.2, accuracy: 1e-9)
        // lost indices with successor: 2,3,4,5 = 4, F→T once → r = 1/4
        XCTAssertEqual(a.recoveryProbabilityAfterLoss, 0.25, accuracy: 1e-9)
    }

    func testMixedLossAndTrailingBurst() {
        let seq = [true, false, true, true, false, false, false]
        let a = PacketLossAnalyzer.analyze(received: seq)
        XCTAssertEqual(a.randomLossEvents, 1)
        XCTAssertEqual(a.burstEvents, 1)
        XCTAssertEqual(a.longestBurst, 3)
        XCTAssertEqual(a.pattern, .mixed)
        XCTAssertEqual(a.randomLossPercent + a.burstLossPercent, a.lossPercent, accuracy: 1e-9)
    }

    func testCustomBurstThreshold() {
        let seq = [true, false, false, true, false, false, false, true]
        let a = PacketLossAnalyzer.analyze(received: seq, burstThreshold: 3)
        XCTAssertEqual(a.randomLossEvents, 1, "a run of 2 is random with threshold 3")
        XCTAssertEqual(a.burstEvents, 1)
    }

    func testEmpty() {
        let a = PacketLossAnalyzer.analyze(received: [])
        XCTAssertEqual(a.sent, 0)
        XCTAssertEqual(a.pattern, .none)
    }
}

final class LatencyStatisticsTests: XCTestCase {
    func testFullComputation() {
        let rtts: [Double?] = [10, 12, nil, 11, 15, 30, 10, 12, 11, 13]
        let samples = rtts.enumerated().map { LatencySample(sequence: $0.offset, offset: Double($0.offset), rttMs: $0.element) }
        let stats = LatencyStatistics.compute(from: samples.shuffled())
        let rtt = try! XCTUnwrap(stats.rtt)
        let received = [10.0, 12, 11, 15, 30, 10, 12, 11, 13]
        XCTAssertEqual(rtt.minimum, 10)
        XCTAssertEqual(rtt.maximum, 30)
        XCTAssertEqual(rtt.average, received.reduce(0, +) / 9, accuracy: 1e-9)
        XCTAssertEqual(rtt.median, 12)
        XCTAssertEqual(rtt.p95, Percentile.value(0.95, in: received)!, accuracy: 1e-9)
        XCTAssertEqual(rtt.p99, Percentile.value(0.99, in: received)!, accuracy: 1e-9)
        // Jitter uses send order even though input was shuffled.
        XCTAssertEqual(rtt.jitter, Jitter.meanConsecutiveDifference(received)!, accuracy: 1e-9)
        XCTAssertEqual(stats.loss.lost, 1)
        XCTAssertEqual(stats.loss.lossPercent, 10, accuracy: 1e-9)
    }

    func testAllLost() {
        let samples = (0..<5).map { LatencySample(sequence: $0, offset: 0, rttMs: nil) }
        let stats = LatencyStatistics.compute(from: samples)
        XCTAssertNil(stats.rtt)
        XCTAssertEqual(stats.loss.lossPercent, 100)
        XCTAssertEqual(stats.loss.pattern, .burst)
    }
}
