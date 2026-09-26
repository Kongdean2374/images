import XCTest
@testable import ChaiNet
import ChaiNetCore
import ChaiNetEngines

@MainActor
final class AppTests: XCTestCase {
    func makeContainer(runner: TestRunner = .mock()) throws -> AppContainer {
        let defaults = UserDefaults(suiteName: "chainet.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.settings.testDuration = .s5
        return AppContainer(history: try SwiftDataHistoryStore(inMemory: true), settings: settings, runner: runner,
                            networkInfo: MockNetworkInfo(), serverDirectory: MockServerDirectory())
    }

    func waitUntil(timeout: Double = 10, _ condition: @escaping @MainActor () -> Bool) async {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testSpeedTestRunCompletesAndPersists() async throws {
        let app = try makeContainer()
        let vm = app.speedTest
        vm.start(kind: .fullSpeedTest, items: SpeedTestView.speedTestItems, onCellular: false)
        XCTAssertTrue(vm.isRunning)
        // testDuration 5 s applies to every timed phase, so a full mock run takes ~12–15 s.
        await waitUntil(timeout: 90) { vm.status == .finished }
        XCTAssertEqual(vm.status, .finished)
        XCTAssertFalse(vm.downloadSamples.isEmpty, "live timeline is exposed")
        XCTAssertNotNil(vm.result?.download)
        XCTAssertEqual(app.history.allResults().count, 1)
        XCTAssertEqual(app.tasks.runningCount, 0, "finished runs unregister")
    }

    func testStopCancelsAndKeepsPartialResult() async throws {
        let app = try makeContainer(runner: .mock(sampleDelay: 0.05))
        let vm = app.makeRunViewModel()
        vm.start(kind: .fullSpeedTest, items: [.ping, .download, .upload], onCellular: false)
        await waitUntil { !vm.downloadSamples.isEmpty }
        vm.stop()
        await waitUntil { vm.status == .cancelled }
        XCTAssertEqual(vm.status, .cancelled)
        XCTAssertEqual(vm.result?.wasCancelled, true)
    }

    func testBackgroundCancelsAllRegisteredTasks() async throws {
        let app = try makeContainer(runner: .mock(sampleDelay: 0.05))
        let vm = app.makeRunViewModel()
        vm.start(kind: .fullSpeedTest, items: [.download, .upload], onCellular: false)
        await waitUntil { app.tasks.runningCount == 1 }
        app.tasks.cancelAll()   // what the app does on scenePhase == .background
        await waitUntil { vm.status != .running }
        XCTAssertEqual(vm.status, .cancelled)
    }

    func testDiagnosticSessionAnalysesAcrossTests() async throws {
        let app = try makeContainer()
        let vm = DiagnosticSessionViewModel(session: DiagnosticSession(title: "t"), app: app)
        vm.addTest(items: [.ping, .packetLoss, .download, .upload])
        await waitUntil(timeout: 90) { vm.session.tests.count == 1 && !vm.isRunning }
        XCTAssertEqual(vm.session.tests.count, 1)
        XCTAssertNotNil(vm.analysis)
        XCTAssertEqual(vm.analysis?.hypotheses.count, RootCause.allCases.count)
        XCTAssertEqual(app.history.sessions().count, 1, "session persisted")
        let report = try XCTUnwrap(vm.makeReport())
        XCTAssertTrue(DiagnosticReportGenerator().text(report).hasPrefix("ChaiNet Diagnostic Report v2"))
    }

    func testHistoryStoreRetentionAndDelete() throws {
        let store = try SwiftDataHistoryStore(inMemory: true)
        var old = TestResult(date: Date().addingTimeInterval(-40 * 86_400), kind: .fullSpeedTest, network: MockNetworkInfo.wifi)
        old.evaluate()
        let recent = TestResult(kind: .dnsBenchmark, network: MockNetworkInfo.wifi)
        try store.save(old)
        try store.save(recent)
        XCTAssertEqual(store.allResults().count, 2)
        try store.applyRetention(days: 30)
        XCTAssertEqual(store.allResults().map(\.id), [recent.id])
        try store.delete(ids: [recent.id])
        XCTAssertTrue(store.allResults().isEmpty)
    }

    func testSettingsPersist() {
        let defaults = UserDefaults(suiteName: "chainet.tests.\(UUID().uuidString)")!
        let a = SettingsStore(defaults: defaults)
        a.settings.primarySpeedUnit = .mBps
        a.settings.secondarySpeedUnit = nil
        let b = SettingsStore(defaults: defaults)
        XCTAssertEqual(b.settings.primarySpeedUnit, .mBps)
        XCTAssertNil(b.settings.secondarySpeedUnit)
        XCTAssertFalse(b.settings.storeLocation, "location is opt-in")
    }

    func testToolCatalogCoversAllRequiredTools() {
        let titles = Set(Tool.allCases.map(\.rawValue))
        for required in ["ping", "jitter", "packetLoss", "burstLoss", "download", "upload", "bufferbloat", "dns", "ipFamilies", "http", "tls",
                         "traceroute", "mtu", "continuousPing", "dropMonitor", "gaming", "voice", "streaming", "serverBenchmark"] {
            XCTAssertTrue(titles.contains(required), required)
        }
    }

    func testEveryStressEngineIsInTheToolbox() {
        let kinds = Set(Tool.allCases.compactMap(\.stressKind))
        XCTAssertEqual(kinds, Set(StressToolKind.allCases))
        XCTAssertTrue(Tool.allCases.filter { $0.stressKind != nil }.allSatisfy { $0.kind == .stressTool })
    }

    func testRecommendedTestMapping() {
        XCTAssertEqual(DiagnosticSessionViewModel.items(for: .compareIPFamilies), [.ipFamilies])
        XCTAssertTrue(DiagnosticSessionViewModel.isManual(.repeatOnLTE), "iOS can't switch radio technology itself")
        XCTAssertNil(DiagnosticSessionViewModel.items(for: .contactProvider))
    }
}

final class SpeedSmoothingTests: XCTestCase {
    func testMovingAverageFlattensBursts() {
        // Alternating 0 / 200 Mbps bursts (100 ms each) → 0.5 s average ≈ 80–120 Mbps, never 0 or 200.
        var cumulative: Int64 = 0
        let raw = (0..<20).map { i -> SpeedSample in
            let bytes: Int64 = i % 2 == 0 ? 0 : 2_500_000
            cumulative += bytes
            return SpeedSample(offset: Double(i + 1) * 0.1, intervalDuration: 0.1, intervalBytes: bytes, cumulativeBytes: cumulative, activeStreams: 4)
        }
        let smooth = SpeedSmoothing.movingAverage(raw, window: 5)
        XCTAssertEqual(smooth.count, raw.count)
        for s in smooth.dropFirst(5) {
            XCTAssertGreaterThan(s.mbps, 70)
            XCTAssertLessThan(s.mbps, 130)
        }
        XCTAssertEqual(smooth.last?.cumulativeBytes, raw.last?.cumulativeBytes, "totals are untouched")
    }

    func testWindowOneIsIdentity() {
        let raw = [SpeedSample(offset: 0.1, intervalDuration: 0.1, intervalBytes: 100, cumulativeBytes: 100, activeStreams: 1)]
        XCTAssertEqual(SpeedSmoothing.movingAverage(raw, window: 1), raw)
    }
}
