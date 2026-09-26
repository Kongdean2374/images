import XCTest
@testable import ChaiNet
import ChaiNetCore

final class LiveChartTests: XCTestCase {
    /// 100 ms samples at `mbps`, with one start-up burst.
    func samples(_ count: Int, mbps: Double, burstAt: Int? = nil) -> [SpeedSample] {
        var cumulative: Int64 = 0
        return (0..<count).map { i in
            let rate = i == burstAt ? mbps * 40 : mbps
            let bytes = Int64(rate * 1_000_000 / 8 * 0.1)
            cumulative += bytes
            return SpeedSample(offset: Double(i + 1) * 0.1, intervalDuration: 0.1, intervalBytes: bytes, cumulativeBytes: cumulative, activeStreams: 8)
        }
    }

    /// Already drawn buckets must not change when more data arrives (no "shaking").
    func testCompletedBinsNeverChange() {
        let all = samples(120, mbps: 50)
        let early = LiveThroughputChart.bins(Array(all.prefix(55)), binSeconds: 0.5)
        let later = LiveThroughputChart.bins(all, binSeconds: 0.5)
        XCTAssertEqual(early.count, 11)
        XCTAssertEqual(Array(later.prefix(early.count)), early)
        XCTAssertEqual(later.first!.mbps, 50, accuracy: 0.01)
    }

    /// One start-up burst must not keep the axis at 1–2 Gbps for a 50 Mbps link.
    /// The smooth curve passes through every point and never overshoots (no fake peak above the
    /// highest value, no dip below zero).
    func testSmoothCurveDoesNotOvershoot() {
        let pts = [CGPoint(x: 0, y: 100), CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 40, y: 100)]
        let box = LiveThroughputChart.linePath(pts).boundingRect
        XCTAssertGreaterThanOrEqual(box.minY, -0.001)
        XCTAssertLessThanOrEqual(box.maxY, 100.001)
        XCTAssertEqual(box.minX, 0, accuracy: 0.001)
        XCTAssertEqual(box.maxX, 40, accuracy: 0.001)
    }

    func testRobustScaleIgnoresSingleBurst() {
        let bins = LiveThroughputChart.bins(samples(100, mbps: 50, burstAt: 2), binSeconds: 0.5)
        XCTAssertGreaterThan(bins.map(\.mbps).max()!, 300, "the burst is in the data")
        let sorted = bins.map(\.mbps).sorted()
        let typical = Percentile.value(0.9, sorted: sorted)!
        XCTAssertEqual(LiveScale.niceCeiling(typical * 1.25), 100)
    }

    func testBinWidthGrowsForLongTests() {
        XCTAssertEqual(LiveThroughputChart.binSeconds(duration: 10, width: 300, minimum: 0.5), 0.5)
        XCTAssertEqual(LiveThroughputChart.binSeconds(duration: 120, width: 300, minimum: 0.5), 2)
        XCTAssertEqual(LiveThroughputChart.binSeconds(duration: 10, width: 300, minimum: 1.2), 1.2)
    }
}
