import Foundation
import ChaiNetCore

extension TestRunner {
    /// Toolbox: one stress engine on its own, with the same engines, data model and analysis as the
    /// Extreme Stress Test. Always measures an idle control baseline first and a recovery after.
    func executeStressTool(_ c: TestRunConfiguration, request: StressToolRequest,
                           emit: @escaping @Sendable (TestRunEvent) -> Void) async throws -> TestResult {
        let scale = min(1, max(c.stressTimeScale, 0.000_1))
        let clock = Stopwatch()
        emit(.phase(.preparing))
        let snapshot = await networkInfo.snapshot(includePublicIP: false)
        emit(.network(snapshot))
        guard snapshot.status == .satisfied else { throw EngineError.noNetwork }
        var result = TestResult(kind: .stressTool, network: snapshot)
        emit(.phase(.selectingServer))

        let nodes = Self.defaultStressNodes(servers: c.candidateServers)
        let throughput = nodes.filter(\.isThroughputCapable)
        let target = request.targetNodeID.flatMap { id in throughput.first { $0.id == id } } ?? throughput.first { $0.provider != .mlab }
        guard let target, let server = target.server else { throw EngineError.server("沒有可用的吞吐量節點") }
        result.server = server
        emit(.serverSelected(server))

        let controlNode = StressNode.latencyOnlyDefaults.first { $0.capabilities.contains(.loss) && stressProbes.icmp(host: $0.host, packetsPerSecond: 4) != nil }
        let descriptor = controlNode.map { ProbeDescriptor(target: $0.host, method: "icmpEcho", protocolName: "ICMP", ipFamily: "IPv4") }
        let environment = EnvironmentRecorder(clock: clock, scale: scale, networkInfo: networkInfo)
        environment.start()
        let monitor = ContinuousLatencyMonitor(probe: controlNode.flatMap { stressProbes.icmp(host: $0.host, packetsPerSecond: 4) },
                                               descriptor: descriptor, intervalSeconds: 0.25, clock: clock, scale: scale, environment: environment)
        monitor.start()
        defer {
            monitor.cancel()
            environment.cancel()
        }
        var limits = c.stressDataLimits.effective(onCellular: c.onCellular)
        if let cap = request.dataLimitBytes { limits = .withHardCap(cap, policy: "userConfigured") }
        let bytes = LockedValue<(down: Int64, up: Int64)>((0, 0))
        let ctx = StressLoadContext(speed: speed, ndt7: ndt7, monitor: monitor, environment: environment, bytes: bytes,
                                    limits: limits, scale: scale, emit: emit)

        // Idle control baseline (same probe the load phases are compared with).
        emit(.phase(.idleLatency))
        let idleStart = monitor.enter("idle", phase: .idleLatency, load: .idle)
        try await ctx.observe(5, phase: .idleLatency, what: "量測閒置基準（固定對照探測，5 秒）", idleBaselineMs: nil)
        await monitor.waitForSamples(since: idleStart, count: 5)
        let idle = monitor.latencySamples(from: idleStart, to: monitor.now)
        result.idleSamples = idle
        result.idleLatency = LatencyStatistics.compute(from: idle)
        let idleMedian = result.idleLatency?.rtt?.median
        var report = StressLoadReport()
        report.idleControlMedianMs = idleMedian
        emit(.partial(result))

        let seconds = max(5, request.durationSeconds)
        let streams = min(max(1, request.maxStreams), 32)
        func reference(_ d: TransferDirection) async throws -> Double? {
            let r = try await ctx.runLoad(server: server, direction: d, streams: min(streams, 16), seconds: 6)
            return r.speed?.bestAverageMbps
        }
        switch request.kind {
        case .streamRamp:
            let stages = StreamRampResult.defaultStages.filter { $0 <= streams }
            report.streamRamp = try await StreamRampEngine().run(ctx, node: target, server: server, stages: stages,
                                                                 stageSeconds: max(2, request.durationSeconds),
                                                                 maxStreams: streams, idleBaselineMs: idleMedian)
        case .sustainedDownload:
            report.sustainedDownload = try await SustainedLoadEngine().run(ctx, node: target, server: server, direction: .download,
                                                                           streams: min(streams, 32), seconds: seconds, idleBaselineMs: idleMedian)
        case .sustainedUpload:
            report.sustainedUpload = try await SustainedLoadEngine().run(ctx, node: target, server: server, direction: .upload,
                                                                         streams: min(streams, 16), seconds: seconds, idleBaselineMs: idleMedian)
        case .fullDuplex:
            // Single-direction references on the same node first, so the degradation is comparable.
            let dl = try await reference(.download)
            let ul = try await reference(.upload)
            report.standardDownloadMbps = dl
            report.standardUploadMbps = ul
            report.fullDuplex = try await FullDuplexStressEngine().run(ctx, node: target, server: server, downloadStreams: min(streams, 32),
                                                                       uploadStreams: min(streams, 16), seconds: seconds, idleBaselineMs: idleMedian,
                                                                       downloadOnlyMbps: dl, uploadOnlyMbps: ul)
        case .burst:
            report.burst = try await BurstStressEngine().run(ctx, node: target, server: server, streams: min(streams, 32),
                                                             cycles: min(max(1, request.burstCycles), 30), idleBaselineMs: idleMedian)
        case .multiDestination:
            var best: Double?
            for node in throughput where node.provider != .mlab {
                if let s = node.server {
                    let r = try await ctx.runLoad(server: s, direction: .download, streams: min(streams, 16), seconds: 6)
                    best = [best, r.speed?.bestAverageMbps].compactMap { $0 }.max()
                }
            }
            report.multiDestination = try await MultiDestinationStressEngine().run(ctx, targets: throughput, streams: min(streams, 16), seconds: seconds,
                                                                                    idleBaselineMs: idleMedian, bestSingleStandardMbps: best)
        case .recovery:
            report.sustainedDownload = try await SustainedLoadEngine().run(ctx, node: target, server: server, direction: .download,
                                                                           streams: min(streams, 32), seconds: seconds, idleBaselineMs: idleMedian)
        case .packetLossStress:
            emit(.phase(.packetLoss))
            monitor.enter("packetLossStress", phase: .packetLossStress, load: .packetLoss)
            let plan = StressTestPlan.make(totalSeconds: 300, nodes: nodes)
            func count(_ s: Double, _ pps: Double, _ minimum: Int) -> Int { max(minimum, Int(s * pps * scale)) }
            let (stress, controls) = await lossStress(plan: plan, seconds: seconds, count: count, interval: { $0 * scale }, emit: emit)
            report.lossProbes = [stress].compactMap { $0 } + controls
            let lc = LossConfirmation.evaluate(stress: stress, controls: controls)
            if let rep = controls.min(by: { abs($0.lossPercent - (lc.confirmedLossPercent ?? 0)) < abs($1.lossPercent - (lc.confirmedLossPercent ?? 0)) }) {
                result.packetLoss = rep.statistics
                result.packetLossSamples = rep.samples
                result.packetLossMethod = "對照探測 \(rep.name)（\(rep.method)，\(Int(rep.packetsPerSecond)) pps）；判定：\(lc.verdict.displayName)"
            }
            report.notes.append("loss_verdict=\(lc.verdict.rawValue)")
        }
        // Recovery after the load (the recovery tool uses the longer final window).
        if request.kind != .packetLossStress {
            emit(.phase(.idleLatency))
            report.recoveries.append(try await RecoveryEngine().run(ctx, kind: request.kind == .recovery ? "final" : "short",
                                                                    afterPhase: request.kind.rawValue,
                                                                    seconds: request.kind == .recovery ? 25 : 8, idleBaselineMs: idleMedian))
        }
        if let blocked = ctx.primaryBlocked.current {
            report.notes.append("http_endpoint_blocked=\(blocked)；之後的負載改用 M-Lab NDT7（單一連線，方法不同，不與 HTTP ×N 直接比較）")
            result.notes.append("壓力負載期間 HTTP 測速端點停止回應（\(blocked)），其餘負載改用 M-Lab NDT7 繼續。")
        }
        if ctx.capReached.current { report.notes.append("已達流量上限，負載提前結束。") }
        report.monitor = await monitor.stop()
        report.environment = await environment.stop()
        result.stressLoad = report
        emit(.phase(.analyzing))
        result.evaluate(scoreEngine: scoreEngine, diagnostics: diagnostics)
        emit(.phase(.done))
        return result
    }
}
