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
