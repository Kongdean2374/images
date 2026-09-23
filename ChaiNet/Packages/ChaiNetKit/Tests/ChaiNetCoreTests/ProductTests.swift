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
        XCTAssertEqual(s.effectiveMaxDuration(onCellular: true), 10, "an explicit duration is honoured exactly")
        s.testDuration = .auto
        XCTAssertEqual(s.effectiveMaxDuration(onCellular: true), 7.5, "auto is halved on cellular in saver mode")
        XCTAssertEqual(s.effectiveMaxDuration(onCellular: false), 15)
        XCTAssertNotNil(s.transferByteCap(onCellular: true))
        XCTAssertNil(s.transferByteCap(onCellular: false))
    }

    func testPhaseTimingAppliesDurationToEveryItem() {
        let t = PhaseTiming.make(.s10)
        XCTAssertEqual(t.idleProbeCount, 100)          // 10 s / 0.1 s
        XCTAssertEqual(t.lossProbeCount, 200)          // 10 s / 0.05 s
        XCTAssertEqual(t.crossValidationProbes, 100)
        XCTAssertEqual(t.ipFamilyProbes, 50)           // 10 s / 0.2 s
        XCTAssertEqual(t.interfaceProbes, 50)
        XCTAssertEqual(t.monitoringSeconds, 10)
        XCTAssertEqual(t.throughputSeconds, 10)
        XCTAssertEqual(PhaseTiming.make(.s30, lossInterval: 0.02).lossProbeCount, 1500)
        let auto = PhaseTiming.make(.auto)
        XCTAssertEqual(auto.idleProbeCount, 20)
        XCTAssertNil(auto.throughputSeconds)
    }

    func testFeatureOverrides() {
        var s = AppSettings()
        s.testDuration = .auto
        var o = RunOverrides()
        o.testDuration = .s30
        o.parallelConnections = .eight
        s.overrides["gaming"] = o
        XCTAssertEqual(s.effective(for: "gaming").testDuration, .s30)
        XCTAssertEqual(s.effective(for: "gaming").parallelConnections, .eight)
        XCTAssertEqual(s.effective(for: "dns").testDuration, .auto, "other features use the global setting")
        XCTAssertEqual(s.effective(for: nil), s)
    }

    func testServerPlans() {
        let servers = ["a", "b", "c", "d"].map { ServerDescriptor(id: $0, name: $0, location: "x", kind: .chainet, baseURL: URL(string: "https://\($0).x")!) }
        var s = AppSettings()
        XCTAssertNil(s.serverPlan(available: servers).primary)
        s.serverSelection = .multiple
        s.selectedServerIDs = ["c", "a", "zz"]
        let plan = s.serverPlan(available: servers)
        XCTAssertEqual(plan.primary?.id, "c")
        XCTAssertEqual(plan.extras.map(\.id), ["a"])
        s.serverSelection = .autoMultiple
        s.autoServerCount = 3
        XCTAssertEqual(s.serverPlan(available: servers).autoExtraCount, 2)
        s.autoServerCount = 10
        XCTAssertEqual(s.serverPlan(available: servers).autoExtraCount, 3)
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
