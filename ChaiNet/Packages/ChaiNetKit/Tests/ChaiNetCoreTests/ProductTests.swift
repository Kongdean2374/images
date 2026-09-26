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

final class FullTestPlanTests: XCTestCase {
    func testTwoMinutePlan() {
        let p = FullTestPlan.make(totalSeconds: 120, serverCount: 1)
        // budget = max(120 − 71, 60) = 60 → download 22 % = 13.2 s
        XCTAssertEqual(p.throughputSeconds, 13.2, accuracy: 0.01)
        XCTAssertEqual(p.monitoringSeconds, 10, accuracy: 0.01, "16 % of 60 = 9.6 → floor 10 s")
        XCTAssertEqual(p.items.count, 13)
        XCTAssertTrue(p.items.contains { $0.key == "traceroute" && !$0.budgeted })
    }

    func testMultiServerSharesServerPhases() {
        let one = FullTestPlan.make(totalSeconds: 600, serverCount: 1)
        let three = FullTestPlan.make(totalSeconds: 600, serverCount: 3)
        XCTAssertEqual(three.throughputSeconds, one.throughputSeconds / 3, accuracy: 0.01)
        XCTAssertEqual(three.estimatedSeconds, one.estimatedSeconds, accuracy: 1, "total time is honoured regardless of server count")
    }

    func testClampsAndFloors() {
        XCTAssertEqual(FullTestPlan.make(totalSeconds: 5).requestedSeconds, 60)
        XCTAssertEqual(FullTestPlan.make(totalSeconds: 99_999).requestedSeconds, 1800)
        let tiny = FullTestPlan.make(totalSeconds: 60, serverCount: 6)
        XCTAssertGreaterThanOrEqual(tiny.throughputSeconds, 6)
        XCTAssertGreaterThanOrEqual(tiny.lossSeconds, 5)
    }

    func testAllItemsIncluded() {
        XCTAssertEqual(FullTestPlan.allItems, Set(TestItem.allCases))
    }
}

final class RawDataExporterTests: XCTestCase {
    func sample() -> TestResult {
        var r = Fixture.result(.nr, download: 300, upload: 20, latency: 15, loss: 2)
        r.idleSamples = (0..<5).map { LatencySample(sequence: $0, offset: Double($0) * 0.1, rttMs: $0 == 3 ? nil : 15) }
        r.packetLossSamples = r.idleSamples
        r.location = GeoPoint(latitude: 25, longitude: 121, horizontalAccuracy: 5)
        r.fullTestPlan = FullTestPlan.make(totalSeconds: 120)
        return r
    }

    func testTextContainsEveryRawSampleAndIsEnglish() {
        let r = sample()
        let text = RawDataExporter.text(r, analysis: RawDataExporter.analysis(for: r), appVersion: "2.0.0", platform: "iOS 26")
        XCTAssertTrue(text.hasPrefix("ChaiNet Raw Data Export v3"))
        for section in ["[meta]", "[full_test_plan]", "[environment]", "[download]", "[upload]", "[latency_idle]", "[root_cause_hypotheses]",
                        "[raw.download_samples_100ms]", "[raw.upload_samples_100ms]", "[raw.idle_latency]", "[raw.packet_loss_probe]"] {
            XCTAssertTrue(text.contains(section), section)
        }
        let rows = text.split(separator: "\n")
        let dlStart = rows.firstIndex { $0 == "[raw.download_samples_100ms]" }!
        XCTAssertEqual(rows[dlStart + 1], "offset_s,interval_s,interval_bytes,cumulative_bytes,active_streams,mbps")
        XCTAssertEqual(rows[(dlStart + 2)...].prefix { !$0.hasPrefix("[") && !$0.isEmpty }.count, r.download!.samples.count)
        XCTAssertTrue(text.contains("3,0.300,lost"), "lost probes are kept")
        XCTAssertTrue(text.contains("cellular_rsrp_dbm=unavailable"))
        XCTAssertFalse(text.contains("25.00000,121"), "location stripped by default")
        // Section / key names are ASCII (values from the network may not be).
        for line in rows where line.hasPrefix("[") { XCTAssertTrue(line.allSatisfy(\.isASCII), String(line)) }
    }

    func testJSONRoundTripKeepsEverything() throws {
        let r = sample()
        let data = try RawDataExporter.json(r, analysis: RawDataExporter.analysis(for: r), appVersion: "2.0.0", platform: "iOS 26")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(RawDataExport.self, from: data)
        XCTAssertEqual(export.schema, "chainet.raw-export")
        XCTAssertEqual(export.result.download?.samples.count, r.download?.samples.count)
        XCTAssertEqual(export.result.packetLossSamples?.count, 5)
        XCTAssertNil(export.result.location)
        XCTAssertEqual(export.analysis?.hypotheses.count, RootCause.allCases.count)
    }
}
