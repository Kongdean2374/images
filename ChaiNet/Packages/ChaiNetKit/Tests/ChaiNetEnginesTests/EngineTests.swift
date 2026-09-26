import XCTest
@testable import ChaiNetEngines
import ChaiNetCore

final class LatencySamplerTests: XCTestCase {
    func testCollectsInSequenceOrder() async {
        let probe = MockLatencyProbe(rtts: [10, nil, 30])
        let samples = await LatencySampler.collect(probe: probe, count: 6, interval: 0.001, timeout: 1)
        XCTAssertEqual(samples.map(\.sequence), Array(0..<6))
        XCTAssertEqual(samples.map(\.rttMs), [10, nil, 30, 10, nil, 30])
    }

    func testCancellationStopsSampling() async {
        let probe = MockLatencyProbe(rtts: [10], delay: 0.01)
        let task = Task { await LatencySampler.collect(probe: probe, count: 10_000, interval: 0.01, timeout: 1) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let samples = await task.value
        XCTAssertLessThan(samples.count, 10_000)
    }
}

final class PendingProbesTests: XCTestCase {
    func testResolveAndExpire() async {
        let pending = PendingProbes()
        async let a = pending.waitForReply(sequence: 1, timeout: 5) {}
        async let b = pending.waitForReply(sequence: 2, timeout: 0.05) {}
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(pending.resolve(sequence: 1))
        XCTAssertFalse(pending.resolve(sequence: 99), "unknown sequence is ignored")
        let (ra, rb) = await (a, b)
        XCTAssertNotNil(ra)
        XCTAssertNil(rb, "timeout → lost")
    }
}

final class UploadPayloadTests: XCTestCase {
    func testSizeAndRandomness() {
        let a = UploadPayload.make(bytes: 1_000_003)
        let b = UploadPayload.make(bytes: 1_000_003)
        XCTAssertEqual(a.count, 1_000_003)
        XCTAssertNotEqual(a, b, "payload must be random (incompressible)")
    }

    func testUDPPacketLayout() {
        let p = UDPEchoProbe.packet(sequence: 0x01020304, size: 64)
        XCTAssertEqual(p.count, 64)
        XCTAssertEqual(Array(p.prefix(8)), Array("CHNT".utf8) + [1, 2, 3, 4])
    }
}

final class SpeedEngineContractTests: XCTestCase {
    func testMockEngineCompletesWithFullTimeline() async throws {
        let server = ServerDescriptor.builtIn[0]
        var samples = 0
        var result: SpeedResult?
        for try await e in MockSpeedTestEngine(mbps: 80, sampleCount: 20).run(SpeedTestConfiguration(server: server, direction: .download)) {
            if case .sample = e { samples += 1 }
            if case .completed(let r) = e { result = r }
        }
        XCTAssertEqual(samples, 20)
        XCTAssertEqual(result?.samples.count, 20)
        XCTAssertEqual(result!.summary.averageMbps, 80, accuracy: 0.1)
    }

    func testServerURLs() {
        let cf = ServerDescriptor.builtIn[0]
        XCTAssertEqual(cf.downloadURL(bytes: 1000).absoluteString, "https://speed.cloudflare.com/__down?bytes=1000")
        XCTAssertEqual(cf.uploadURL().absoluteString, "https://speed.cloudflare.com/__up")
        let own = ServerDescriptor(id: "x", name: "x", location: "x", kind: .chainet, baseURL: URL(string: "https://t.example:8443")!)
        XCTAssertEqual(own.downloadURL(bytes: 5).absoluteString, "https://t.example:8443/download?bytes=5")
        XCTAssertEqual(own.pingURL().absoluteString, "https://t.example:8443/ping")
    }
}

final class TestRunnerTests: XCTestCase {
    func config(_ items: Set<TestItem>, kind: TestKind = .fullSpeedTest) -> TestRunConfiguration {
        var settings = AppSettings()
        settings.testDuration = .s5
        return TestRunConfiguration(kind: kind, items: items, candidateServers: ServerDescriptor.builtIn, settings: settings, onCellular: false)
    }

    func run(_ c: TestRunConfiguration) async throws -> (TestResult, [TestPhase]) {
        var phases: [TestPhase] = []
        var final: TestResult?
        for try await e in TestRunner.mock().run(c) {
            if case .phase(let p) = e { phases.append(p) }
            if case .completed(let r) = e { final = r }
        }
        return (try XCTUnwrap(final), phases)
    }

    func testSpeedTestFlowOrderAndResults() async throws {
        let (r, phases) = try await run(config([.ping, .jitter, .packetLoss, .download, .upload, .bufferbloat]))
        XCTAssertLessThan(phases.firstIndex(of: .idleLatency)!, phases.firstIndex(of: .download)!)
        XCTAssertLessThan(phases.firstIndex(of: .download)!, phases.firstIndex(of: .upload)!)
        XCTAssertNotNil(r.download)
        XCTAssertNotNil(r.upload)
        XCTAssertNotNil(r.idleLatency)
        XCTAssertNotNil(r.packetLoss)
        XCTAssertNotNil(r.bufferbloat)
        XCTAssertNotNil(r.scores.overall)
        XCTAssertEqual(r.packetLoss?.loss.lossPercent ?? 0, 25, accuracy: 0.01, "mock loss probe drops 1 of 4")
    }

    func testIndependentToolRunsOnlyItsItems() async throws {
        let (r, phases) = try await run(config([.dns]))
        XCTAssertNotNil(r.dns)
        XCTAssertNil(r.download)
        XCTAssertNil(r.idleLatency)
        XCTAssertFalse(phases.contains(.download))
    }

    func testAutoCrossValidationTriggersOnLoss() async throws {
        // Mock loss probe has 25 % loss → primary abnormal → cross-validation runs automatically.
        let (r, _) = try await run(config([.ping, .packetLoss]))
        XCTAssertNotNil(r.crossValidation)
        XCTAssertEqual(r.crossValidation?.first?.isPrimary, true)
    }

    func testGamingQualityVerdicts() async throws {
        var c = TestRunConfiguration.quality(.gaming, servers: ServerDescriptor.builtIn, fixedServer: nil, settings: AppSettings(), onCellular: false)
        c.lossProbeCount = 50
        c.lossProbeInterval = 0.001
        let (r, _) = try await run(c)
        XCTAssertNotNil(r.gaming)
        XCTAssertEqual(r.gaming?.verdicts.count, GameGenre.allCases.count)
    }

    func testCancellationStopsRunner() async throws {
        let runner = TestRunner.mock(sampleDelay: 0.05)
        let configuration = config([.download, .upload])
        let task = Task {
            var count = 0
            for try await _ in runner.run(configuration) { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

final class ExtremeFullTestTests: XCTestCase {
    func testExtremeConfigurationRunsEveryItemAtMaximumLoad() async throws {
        var settings = AppSettings()
        settings.trafficUsage = .saveOnCellular
        let plan = FullTestPlan.make(totalSeconds: 60)
        var config = TestRunConfiguration.extreme(plan: plan, servers: ServerDescriptor.builtIn, fixedServer: nil, settings: settings, onCellular: true)
        XCTAssertEqual(config.items, Set(TestItem.allCases))
        XCTAssertEqual(config.settings.parallelConnections, .sixteen)
        XCTAssertEqual(config.settings.trafficUsage, .unlimited)
        XCTAssertEqual(config.throughputSecondsOverride, plan.throughputSeconds)
        XCTAssertEqual(config.lossProbeCount, Int(plan.lossSeconds / 0.02))

        // Fast mock run: keep the plan shape but shrink the timed phases.
        config.monitoringSeconds = 1
        config.lossProbeInterval = 0.001
        config.lossProbeCount = 20
        var final: TestResult?
        for try await e in TestRunner.mock().run(config) { if case .completed(let r) = e { final = r } }
        let r = try XCTUnwrap(final)
        XCTAssertEqual(r.kind, .extremeFullTest)
        XCTAssertNotNil(r.fullTestPlan)
        XCTAssertNotNil(r.gaming); XCTAssertNotNil(r.voice); XCTAssertNotNil(r.streaming); XCTAssertNotNil(r.obs)
        XCTAssertNotNil(r.packetLossSamples)
        XCTAssertNotNil(r.dns); XCTAssertNotNil(r.traceroute); XCTAssertNotNil(r.mtu); XCTAssertNotNil(r.monitoring)
    }
}

final class StressTestRunnerTests: XCTestCase {
    func run(_ runner: TestRunner, seconds: Double = 300, limits: StressDataLimits = .unlimited) async throws -> (TestResult, [StressProgress]) {
        let nodes = TestRunner.defaultStressNodes(servers: ServerDescriptor.builtIn)
        var config = TestRunConfiguration(kind: .extremeStressTest, items: [], candidateServers: ServerDescriptor.builtIn,
                                          settings: AppSettings(), onCellular: false)
        config.stressPlan = StressTestPlan.make(totalSeconds: seconds, nodes: nodes)
        config.stressWarnings = ["test warning"]
        config.stressTimeScale = 0.001
        config.stressDataLimits = limits
        var final: TestResult?
        var progress: [StressProgress] = []
        for try await e in runner.run(config) {
            if case .completed(let r) = e { final = r }
            if case .stressProgress(let p) = e { progress.append(p) }
        }
        return (try XCTUnwrap(final), progress)
    }

    func testMultiNodeRoundsAndTotals() async throws {
        let (r, progress) = try await run(TestRunner.mock(sampleDelay: 0))
        XCTAssertEqual(r.kind, .extremeStressTest)
        let s = try XCTUnwrap(r.stress)
        XCTAssertEqual(s.testMode, "extremeStressTest")
        XCTAssertEqual(s.plan.rounds, 2)
        // Cloudflare (HTTP x16) and M-Lab (NDT7) in both rounds, both directions.
        XCTAssertEqual(s.transfers.count, 8)
        XCTAssertTrue(s.transfers.contains { $0.method == "NDT7 WebSocket x1" })
        XCTAssertTrue(s.transfers.contains { $0.method == "HTTP x16" })
        XCTAssertEqual(s.downloadAggregate?.values.count, 2)
        XCTAssertGreaterThan(s.totalDownloadBytes, 0)
        XCTAssertGreaterThan(s.totalUploadBytes, 0)
        XCTAssertEqual(s.postLoadLatency.count, 2)
        XCTAssertNotNil(s.stressProbe)
        XCTAssertEqual(s.stressProbe?.packetsPerSecond, 50)
        XCTAssertGreaterThanOrEqual(s.controlProbes.count, 3, "primary ICMP + two independent ICMP")
        XCTAssertTrue(s.controlProbes.allSatisfy(\.isPacketLossProbe), "no QUIC handshakes in the loss verdict")
        XCTAssertNil(r.download, "generic sections never expose a single node's transfer")
        XCTAssertNotNil(s.recycledSeconds)
        XCTAssertTrue(s.controlProbes.allSatisfy { $0.packetsPerSecond == 5 })
        XCTAssertTrue(Set(s.phases.map(\.kind)).isSuperset(of: [.healthCheck, .idleLatency, .downloadStress, .uploadStress, .postLoadRecovery,
                                                                 .packetLossStress, .monitoring, .dnsProtocols, .ipFamilies, .crossServerValidation, .routeMTU]))
        XCTAssertFalse(progress.isEmpty)
        XCTAssertNotNil(r.dns); XCTAssertNotNil(r.traceroute); XCTAssertNotNil(r.monitoring); XCTAssertNotNil(r.ipFamilyComparison)
        XCTAssertTrue(r.notes.contains("test warning"))
        XCTAssertNotNil(s.score)
    }

    func testOneFailingEndpointDoesNotFailTheTest() async throws {
        var runner = TestRunner.mock(sampleDelay: 0)
        runner.stressProbes = MockStressProbeFactory(unhealthyNodeIDs: ["mlab-ndt7", "quad9-dns"])
        let (r, _) = try await run(runner)
        let s = try XCTUnwrap(r.stress)
        XCTAssertEqual(s.nodes.first { $0.id == "mlab-ndt7" }?.healthy, false)
        XCTAssertFalse(s.transfers.contains { $0.nodeID == "mlab-ndt7" })
        XCTAssertFalse(s.transfers.isEmpty)
        XCTAssertEqual(s.nodes.count, TestRunner.defaultStressNodes(servers: ServerDescriptor.builtIn).count, "unhealthy nodes stay in the report")
    }

    func testStressOnlyICMPLossIsRateLimiting() async throws {
        var runner = TestRunner.mock(sampleDelay: 0)
        runner.stressProbes = MockStressProbeFactory(controlRTTs: [15, 16], stressRTTs: [15, nil, nil, 16])
        let (r, _) = try await run(runner, seconds: 60)
        let s = try XCTUnwrap(r.stress)
        XCTAssertEqual(s.lossConfirmation.verdict, .possibleICMPRateLimiting)
        XCTAssertEqual(r.metrics.lossPercent ?? -1, 0, accuracy: 1e-9)
        XCTAssertFalse(r.findings.contains { $0.code == .severePacketLoss || $0.code == .moderatePacketLoss })
    }

    /// Mobile-data hard cap: throughput phases stop, low-data diagnostics still complete.
    func testHardCapStopsThroughputButFinishesDiagnostics() async throws {
        let (r, _) = try await run(TestRunner.mock(sampleDelay: 0), limits: StressDataLimits(warningBytes: 1, hardCapBytes: 1))
        let s = try XCTUnwrap(r.stress)
        XCTAssertEqual(s.dataCapReached, true)
        XCTAssertEqual(s.dataLimits?.hardCapBytes, 1)
        XCTAssertLessThan(s.transfers.count, 8, "transfers after the cap are skipped")
        XCTAssertTrue(s.phases.contains { $0.note == "skipped: dataCapReached" })
        XCTAssertNotNil(r.dns); XCTAssertNotNil(r.traceroute); XCTAssertNotNil(r.monitoring)
        XCTAssertTrue(Set(s.phases.map(\.kind)).isSuperset(of: [.packetLossStress, .dnsProtocols, .ipFamilies, .routeMTU]))
        XCTAssertTrue(r.notes.contains { $0.contains("已達流量上限") })
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.0", platform: "iOS")
        XCTAssertTrue(text.contains("data_cap_reached=true"))
        XCTAssertTrue(text.contains("data_hard_cap_bytes=1"))
    }

    /// Cellular with nothing configured runs under the 1.5 GB default, never silently unlimited.
    func testCellularRunUsesDefaultCap() async throws {
        let nodes = TestRunner.defaultStressNodes(servers: ServerDescriptor.builtIn)
        var config = TestRunConfiguration(kind: .extremeStressTest, items: [], candidateServers: ServerDescriptor.builtIn,
                                          settings: AppSettings(), onCellular: true)
        config.stressPlan = StressTestPlan.make(totalSeconds: 60, nodes: nodes)
        config.stressTimeScale = 0.001
        var final: TestResult?
        for try await e in TestRunner.mock(sampleDelay: 0).run(config) { if case .completed(let r) = e { final = r } }
        let r = try XCTUnwrap(final)
        XCTAssertEqual(r.stress?.dataLimits?.policy, "cellularDefault")
        XCTAssertEqual(r.stress?.dataLimits?.hardCapBytes, 1_500_000_000)
        XCTAssertTrue(r.notes.contains { $0.contains("行動網路預設流量保護") })
    }

    /// The pre-test estimate is updated from observed throughput after round 1, and exceeding it warns.
    func testTrafficProjectionUpdatesAndWarns() async throws {
        let nodes = TestRunner.defaultStressNodes(servers: ServerDescriptor.builtIn)
        var config = TestRunConfiguration(kind: .extremeStressTest, items: [], candidateServers: ServerDescriptor.builtIn,
                                          settings: AppSettings(), onCellular: false)
        config.stressPlan = StressTestPlan.make(totalSeconds: 300, nodes: nodes)
        config.stressTimeScale = 0.001
        config.stressDataLimits = .withHardCap(1_000_000_000_000)
        config.stressTrafficEstimate = TrafficEstimate(downloadBytes: 1, uploadBytes: 1, assumedDownloadMbps: 0.001, assumedUploadMbps: 0.001)
        var final: TestResult?
        var projections: [Int64] = []
        for try await e in TestRunner.mock(sampleDelay: 0).run(config) {
            if case .completed(let r) = e { final = r }
            if case .stressProgress(let p) = e, let v = p.projectedBytes { projections.append(v) }
        }
        let p = try XCTUnwrap(final?.stress?.trafficProjection)
        XCTAssertEqual(p.originalEstimateBytes, 2)
        XCTAssertNotNil(p.updatedEstimateBytes)
        XCTAssertEqual(p.updatedBasis, "afterRound1ObservedThroughput")
        XCTAssertNotNil(p.observedDownloadMbps)
        XCTAssertEqual(p.warning, "projectedExceedsOriginalEstimate")
        XCTAssertFalse(projections.isEmpty, "live progress carries the projection")
        XCTAssertTrue(final!.notes.contains { $0.contains("高於測試前預估範圍") })
    }

    func testUnlimitedRunNeverReportsCap() async throws {
        let (r, _) = try await run(TestRunner.mock(sampleDelay: 0), seconds: 60)
        XCTAssertNotEqual(r.stress?.dataCapReached, true)
    }

    func testNDT7ServerSampleParsing() {
        let s = NDT7SpeedTestEngine.serverSample(from: #"{"AppInfo":{"NumBytes":1250000,"ElapsedTime":2000000},"Origin":"server"}"#)
        XCTAssertEqual(s?.bytes, 1_250_000)
        XCTAssertEqual(s?.offset ?? 0, 2, accuracy: 1e-9)
        let tcp = NDT7SpeedTestEngine.serverSample(from: #"{"TCPInfo":{"BytesReceived":500,"ElapsedTime":500000}}"#)
        XCTAssertEqual(tcp?.bytes, 500)
        XCTAssertNil(NDT7SpeedTestEngine.serverSample(from: "not json"))
        XCTAssertNil(NDT7SpeedTestEngine.serverSample(from: #"{"ConnectionInfo":{}}"#))
    }

    func testCancellation() async throws {
        let nodes = TestRunner.defaultStressNodes(servers: ServerDescriptor.builtIn)
        var config = TestRunConfiguration(kind: .extremeStressTest, items: [], candidateServers: ServerDescriptor.builtIn,
                                          settings: AppSettings(), onCellular: false)
        config.stressPlan = StressTestPlan.make(totalSeconds: 900, nodes: nodes)
        let task = Task {
            var n = 0
            for try await _ in TestRunner.mock(sampleDelay: 0.05).run(config) { n += 1 }
            return n
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { _ = try await task.value } catch is CancellationError {} catch {}
    }
}

final class TimeoutTests: XCTestCase {
    /// Regression: the stress test hung in DNS because the old `withTimeout` (a task group) waited
    /// for an operation stuck on a UDP reply that never arrived.
    func testReturnsEvenIfOperationNeverFinishes() async {
        let stopwatch = Stopwatch()
        do {
            _ = try await withTimeout(0.2) {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }   // never resumes
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? EngineError, .timeout)
        }
        XCTAssertLessThan(stopwatch.elapsed, 2)
    }

    func testValueBeforeDeadline() async throws {
        let v = try await withTimeout(5) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testCallerCancellation() async {
        let task = Task {
            try await withTimeout(30) { await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in } }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let stopwatch = Stopwatch()
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(stopwatch.elapsed, 2)
    }

    func testStressWatchdogSkipsStuckPhase() async throws {
        var runner = TestRunner.mock(sampleDelay: 0)
        runner.dns = StuckDNSEngine()
        var notes: [String] = []
        let r: DNSBenchmarkResult? = try await runner.guarded(0.2, "DNS 測試", &notes) {
            try await StuckDNSEngine().run(resolvers: [], domains: []) { _ in }
        }
        XCTAssertNil(r)
        XCTAssertTrue(notes.first?.contains("逾時") == true)
    }
}

struct StuckDNSEngine: DNSBenchmarkEngineProtocol {
    func run(resolvers: [DNSResolverDescriptor], domains: [String],
             progress: @escaping @Sendable (DNSResolverResult) -> Void) async throws -> DNSBenchmarkResult {
        await withCheckedContinuation { (_: CheckedContinuation<DNSBenchmarkResult, Never>) in }
    }
}


final class StressTransferValidityRunnerTests: XCTestCase {
    func run(_ runner: TestRunner) async throws -> TestResult {
        let nodes = TestRunner.defaultStressNodes(servers: ServerDescriptor.builtIn)
        var config = TestRunConfiguration(kind: .extremeStressTest, items: [], candidateServers: ServerDescriptor.builtIn,
                                          settings: AppSettings(), onCellular: true)
        config.stressPlan = StressTestPlan.make(totalSeconds: 300, nodes: nodes)
        config.stressTimeScale = 0.001
        var final: TestResult?
        for try await e in runner.run(config) { if case .completed(let r) = e { final = r } }
        return try XCTUnwrap(final)
    }

    /// v2.1.1: Cloudflare round 2 download returned a tiny body (0.005 Mbps) and was counted.
    /// HTTP engine call order: r1 ↓, r1 ↑, r2 ↓ (tiny), r2 ↓ retry (tiny), r2 ↑.
    func testTinyRound2IsRetriedThenExcluded() async throws {
        var runner = TestRunner.mock(sampleDelay: 0)
        runner.speed = MockSpeedTestEngine(ratesByCall: [431, 50, 0.005, 0.005, 50])
        let r = try await run(runner)
        let s = try XCTUnwrap(r.stress)
        let attempts = s.transfers.filter { $0.nodeID == "cloudflare" && $0.round == 2 && $0.direction == .download }
        XCTAssertEqual(attempts.map { $0.attempt ?? 1 }, [1, 2])
        XCTAssertTrue(attempts.allSatisfy { !$0.isValid && $0.validity?.reason == .insufficientPayload })
        XCTAssertEqual(s.failedSlots().count, 1)
        XCTAssertEqual(s.downloadAggregate!.values.first { $0.nodeID == "cloudflare" }!.mbps, 431, accuracy: 1)
        XCTAssertEqual(s.scoreConfidence, .medium)
        XCTAssertTrue(r.notes.contains { $0.contains("重試仍失敗") })
        XCTAssertNotEqual(r.stress?.lossConfirmation.verdict, .inconclusive)
    }

    func testRetryRecovers() async throws {
        var runner = TestRunner.mock(sampleDelay: 0)
        runner.speed = MockSpeedTestEngine(ratesByCall: [431, 50, 0.005, 420, 50])
        let result = try await run(runner)
        let s = try XCTUnwrap(result.stress)
        XCTAssertTrue(s.failedSlots().isEmpty)
        XCTAssertEqual(s.invalidTransfers().count, 1, "the failed first attempt is kept as evidence")
        XCTAssertEqual(s.transfers(.download).filter { $0.nodeID == "cloudflare" }.count, 2)
    }

    func testBatchedUploadThroughRunner() async throws {
        var runner = TestRunner.mock(sampleDelay: 0)
        runner.speed = MockSpeedTestEngine(mbps: 200, sampleCount: 80, batchedUpload: true)
        runner.ndt7 = MockSpeedTestEngine(mbps: 100, sampleCount: 80, batchedUpload: true)
        let r = try await run(runner)
        let s = try XCTUnwrap(r.stress)
        XCTAssertNil(s.stability(.upload))
        XCTAssertEqual(s.stabilityUnavailableReason(.upload), "measurementSamplingArtifact")
        XCTAssertNotNil(s.stability(.download))
        XCTAssertFalse(r.findings.contains { $0.code == .unstableUpload })
    }
}
