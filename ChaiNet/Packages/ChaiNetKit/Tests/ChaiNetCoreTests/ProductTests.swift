import XCTest
@testable import ChaiNetCore

final class SpeedUnitTests: XCTestCase {
    func testConversions() {
        XCTAssertEqual(SpeedFormatter.convert(mbps: 524, to: .mBps), 65.5, accuracy: 1e-9)
        XCTAssertEqual(SpeedFormatter.convert(mbps: 1, to: .kbps), 1000, accuracy: 1e-9)
        XCTAssertEqual(SpeedFormatter.convert(mbps: 2500, to: .gbps), 2.5, accuracy: 1e-9)
        XCTAssertEqual(SpeedFormatter.convert(mbps: 8, to: .kBps), 1000, accuracy: 1e-9)
        XCTAssertEqual(SpeedFormatter.convert(mbps: 8000, to: .gBps), 1, accuracy: 1e-9)
    }

    func testAutoResolution() {
        XCTAssertEqual(SpeedFormatter.resolve(.auto, mbps: 0.5), .kbps)
        XCTAssertEqual(SpeedFormatter.resolve(.auto, mbps: 50), .mbps)
        XCTAssertEqual(SpeedFormatter.resolve(.auto, mbps: 1500), .gbps)
        XCTAssertEqual(SpeedFormatter.resolve(.mBps, mbps: 1500), .mBps)
    }

    func testDualFormatting() {
        XCTAssertEqual(SpeedFormatter.dual(mbps: 524, primary: .mbps, secondary: .mBps), "524 Mbps ≈ 65.5 MB/s")
        XCTAssertEqual(SpeedFormatter.dual(mbps: 524, primary: .mbps, secondary: nil), "524 Mbps")
        XCTAssertEqual(SpeedFormatter.dual(mbps: 5.25, primary: .auto, secondary: .mbps), "5.25 Mbps")
    }
}

final class ProfileAndWizardTests: XCTestCase {
    func testBuiltInProfiles() {
        XCTAssertEqual(TestProfile.gaming.items, [.ping, .jitter, .packetLoss, .burstLoss, .latencySpikes])
        XCTAssertTrue(TestProfile.cellular.items.isSuperset(of: [.download, .upload, .jitter, .packetLoss, .bufferbloat, .ipFamilies]))
        XCTAssertTrue(TestProfile.fullDiagnostics.items.contains(.crossValidation))
        XCTAssertEqual(Set(TestProfile.builtIn.map(\.id)).count, TestProfile.builtIn.count)
    }

    func testOrderedItemsRunIdleBeforeLoad() {
        let order = TestProfile.fullDiagnostics.orderedItems
        XCTAssertLessThan(order.firstIndex(of: .ping)!, order.firstIndex(of: .download)!)
    }

    func testWizardSelectsOnlyNeededTests() {
        let gaming = TroubleshootingPlanner.profile(for: [.gamingLag]).items
        XCTAssertTrue(gaming.isSuperset(of: [.ping, .jitter, .packetLoss, .latencySpikes]))
        XCTAssertFalse(gaming.contains(.download), "gaming lag does not need a download test")
        let web = TroubleshootingPlanner.profile(for: [.slowWebsites]).items
        XCTAssertTrue(web.isSuperset(of: [.dns, .http, .tls]))
        let both = TroubleshootingPlanner.profile(for: [.gamingLag, .slowWebsites]).items
        XCTAssertEqual(both, gaming.union(web))
        XCTAssertTrue(TroubleshootingPlanner.manualSteps(for: [.cellularOnlyProblem]).contains(.repeatOnLTE))
    }
}

final class SettingsTests: XCTestCase {
    func testDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.appearance, .dark)
        XCTAssertFalse(s.storeLocation, "location storage is opt-in")
        XCTAssertEqual(s.parallelConnections, .auto)
    }

    func testTolerantDecodingAndNullRoundTrip() throws {
        var s = AppSettings()
        s.secondarySpeedUnit = nil
        s.primarySpeedUnit = .gbps
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(decoded.secondarySpeedUnit)
        XCTAssertEqual(decoded.primarySpeedUnit, .gbps)

        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"chartStyle":"bar","unknownKey":1}"#.utf8))
        XCTAssertEqual(partial.chartStyle, .bar)
        XCTAssertEqual(partial.secondarySpeedUnit, .mBps, "missing keys keep defaults")
    }

    func testTrafficRules() {
        var s = AppSettings()
        s.testDuration = .s10
        s.trafficUsage = .saveOnCellular
        XCTAssertEqual(s.effectiveMaxDuration(onCellular: true), 5)
        XCTAssertEqual(s.effectiveMaxDuration(onCellular: false), 10)
        XCTAssertNotNil(s.transferByteCap(onCellular: true))
        XCTAssertNil(s.transferByteCap(onCellular: false))
    }

    func testAutoDuration() {
        let p = AutoDurationPolicy()
        XCTAssertFalse(p.shouldStop(elapsed: 3, recentMbps: Array(repeating: 100, count: 30)))
        XCTAssertTrue(p.shouldStop(elapsed: 7, recentMbps: Array(repeating: 100, count: 30)))
        XCTAssertFalse(p.shouldStop(elapsed: 7, recentMbps: (0..<30).map { $0 % 2 == 0 ? 50 : 150 }))
        XCTAssertTrue(p.shouldStop(elapsed: 15, recentMbps: []))
    }
}

final class HistoryDashboardTests: XCTestCase {
    func testRangeFilterAndTrends() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Fixture.result(.wifi, download: 100, date: now.addingTimeInterval(-3600))
        let old = Fixture.result(.lte, download: 50, date: now.addingTimeInterval(-10 * 86_400))
        XCTAssertEqual(HistoryAggregator.filter([recent, old], range: .days7, now: now).count, 1)
        XCTAssertEqual(HistoryAggregator.filter([recent, old], range: .all, now: now).count, 2)
        XCTAssertEqual(HistoryAggregator.filter([recent, old], range: .all, network: .lte, now: now).count, 1)
        let trend = HistoryAggregator.trends([recent, old]).first { $0.metric == .downloadMbps }!
        XCTAssertEqual(trend.points.count, 2)
        XCTAssertEqual(trend.points.first?.network, .lte, "sorted by date")
        let medians = HistoryAggregator.medianByNetwork([recent, old], metric: .downloadMbps)
        XCTAssertEqual(medians[.wifi]!, 100, accuracy: 1)
    }
}
