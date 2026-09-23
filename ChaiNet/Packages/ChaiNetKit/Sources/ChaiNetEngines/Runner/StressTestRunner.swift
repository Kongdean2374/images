import Foundation
import ChaiNetCore

/// Live progress of the Extreme Stress Test.
public struct StressProgress: Sendable, Hashable {
    public var kind: StressPhaseKind
    public var round: Int?
    public var nodeName: String?
    public var phaseIndex: Int
    public var phaseCount: Int
    public var elapsed: Double
    public var downloadBytes: Int64
    public var uploadBytes: Int64
}

/// Probes to arbitrary stress-test nodes (control probes, health checks). Injected for tests.
public protocol StressProbeFactory: Sendable {
    /// ICMP echo at the given rate; nil when the host is not an IPv4 literal.
    func icmp(host: String, packetsPerSecond: Double) -> (any LatencyProbe)?
    func tcp(host: String, port: UInt16) -> any LatencyProbe
    /// Each probe is a fresh QUIC handshake (UDP 443 path).
    func quic(host: String) -> any LatencyProbe
    func udpEcho(host: String, port: UInt16) -> any LatencyProbe
    /// Health of a node that is not an HTTP speed server (M-Lab Locate, latency-only nodes).
    func health(of node: StressNode) async -> (healthy: Bool, ms: Double?, detail: String?)
}

/// One QUIC handshake (ALPN h3) per probe.
public struct QUICHandshakeProbe: LatencyProbe {
    public let host: String
    public var method: EndpointProbeMethod { .quicHandshake }
    public var targetDescription: String { "QUIC \(host):443" }
    public init(host: String) { self.host = host }
    public func prepare() async throws {}
    public func close() async {}
    public func probe(sequence: Int, timeout: Double) async -> Double? {
        if case .success(let ms) = await QUICProbe.handshake(host: host, timeout: timeout) { return ms }
        return nil
    }
}

public struct DefaultStressProbeFactory: StressProbeFactory {
    public init() {}
    public func icmp(host: String, packetsPerSecond: Double) -> (any LatencyProbe)? {
        SocketSupport.isIPv4Literal(host) ? ICMPEchoProbe(host: host, payloadSize: 56) : nil
    }
    public func tcp(host: String, port: UInt16) -> any LatencyProbe { TCPConnectProbe(host: host, port: port) }
    public func quic(host: String) -> any LatencyProbe { QUICHandshakeProbe(host: host) }
    public func udpEcho(host: String, port: UInt16) -> any LatencyProbe { UDPEchoProbe(host: host, port: port, payloadSize: 64) }

    public func health(of node: StressNode) async -> (healthy: Bool, ms: Double?, detail: String?) {
        if node.provider == .mlab {
            let stopwatch = Stopwatch()
            do {
                let t = try await NDT7SpeedTestEngine.locate(node.server?.baseURL ?? ServerDescriptor.mlabNDT7.baseURL)
                return (true, stopwatch.elapsedMs, "\(t.machine)\(t.city.map { "（\($0)）" } ?? "")")
            } catch {
                return (false, nil, error.localizedDescription)
            }
        }
        let rtt = await TCPConnectProbe(host: node.host, port: 443).probe(sequence: 0, timeout: 3)
        return (rtt != nil, rtt, rtt == nil ? "TCP 443 無回應" : nil)
    }
}

public struct MockStressProbeFactory: StressProbeFactory {
    public var controlRTTs: [Double?]
    public var stressRTTs: [Double?]
    public var unhealthyNodeIDs: Set<String>
    public init(controlRTTs: [Double?] = [15, 16, 15, 17], stressRTTs: [Double?] = [15, 16, 15, 17], unhealthyNodeIDs: Set<String> = []) {
        self.controlRTTs = controlRTTs
        self.stressRTTs = stressRTTs
        self.unhealthyNodeIDs = unhealthyNodeIDs
    }
    public func icmp(host: String, packetsPerSecond: Double) -> (any LatencyProbe)? {
        MockLatencyProbe(rtts: packetsPerSecond >= 20 ? stressRTTs : controlRTTs)
    }
    public func tcp(host: String, port: UInt16) -> any LatencyProbe { MockLatencyProbe(rtts: controlRTTs) }
    public func quic(host: String) -> any LatencyProbe { MockLatencyProbe(rtts: controlRTTs) }
    public func udpEcho(host: String, port: UInt16) -> any LatencyProbe { MockLatencyProbe(rtts: controlRTTs) }
    public func health(of node: StressNode) async -> (healthy: Bool, ms: Double?, detail: String?) {
        unhealthyNodeIDs.contains(node.id) ? (false, nil, "mock down") : (true, 12, nil)
    }
}

// MARK: - Runner

extension TestRunner {
    /// Default node set: Cloudflare Speed, M-Lab NDT7, the user's ChaiNet backends (throughput),
    /// plus independent latency / protocol-only nodes.
    public static func defaultStressNodes(servers: [ServerDescriptor]) -> [StressNode] {
        var nodes: [StressNode] = []
        if let cf = servers.first(where: { $0.kind == .cloudflare }) ?? ServerDescriptor.builtIn.first { nodes.append(.throughputNode(for: cf)) }
        nodes.append(.throughputNode(for: .mlabNDT7))
        nodes += servers.filter { $0.kind == .chainet }.map(StressNode.throughputNode(for:))
        return nodes + StressNode.latencyOnlyDefaults
    }

    /// Extreme Stress Test. Every phase tolerates endpoint failures (recorded, never fatal);
    /// only cancellation or having no network stops the run.
    func executeStress(_ c: TestRunConfiguration, plan requested: StressTestPlan,
                       emit: @escaping @Sendable (TestRunEvent) -> Void) async throws -> TestResult {
        let scale = min(1, max(c.stressTimeScale, 0.000_1))
        func interval(_ seconds: Double) -> Double { seconds * scale }
        func count(_ seconds: Double, pps: Double, minimum: Int) -> Int { max(minimum, Int(seconds * pps * scale)) }
        let clock = Stopwatch()

        emit(.phase(.preparing))
        let snapshot = await networkInfo.snapshot(includePublicIP: true)
        emit(.network(snapshot))
        guard snapshot.status == .satisfied else { throw EngineError.noNetwork }
        var result = TestResult(kind: .extremeStressTest, network: snapshot)
        var records: [StressPhaseRecord] = []
        var transfers: [StressTransferResult] = []
        var phaseIndex = 0
        let bytes = LockedValue<(down: Int64, up: Int64)>((0, 0))

        func begin(_ kind: StressPhaseKind, round: Int? = nil, node: String? = nil, total: Int) -> (Double, Int64, Int64) {
            phaseIndex += 1
            let b = bytes.current
            emit(.stressProgress(StressProgress(kind: kind, round: round, nodeName: node, phaseIndex: phaseIndex, phaseCount: total,
                                                elapsed: clock.elapsed, downloadBytes: b.down, uploadBytes: b.up)))
            return (clock.elapsed, b.down, b.up)
        }
        func end(_ kind: StressPhaseKind, _ start: (Double, Int64, Int64), planned: Double, round: Int? = nil, node: String? = nil, note: String? = nil) {
            let b = bytes.current
            records.append(StressPhaseRecord(kind: kind, round: round, nodeID: node, plannedSeconds: planned, startOffset: start.0,
                                             actualSeconds: clock.elapsed - start.0, downloadBytes: b.down - start.1, uploadBytes: b.up - start.2,
                                             note: note))
        }

        // 1. Health check — every node, concurrently. Unhealthy nodes are kept in the report, skipped in the run.
        emit(.phase(.selectingServer))
        var hc = begin(.healthCheck, total: requested.phases.count)
        var nodes = requested.nodes
        await withTaskGroup(of: (Int, Bool, Double?, String?, UInt16?).self) { group in
            for (i, node) in nodes.enumerated() {
                group.addTask {
                    if let server = node.server, node.provider != .mlab {
                        let h = await self.servers.health(for: server)
                        var port: UInt16?
                        if node.provider == .chainet { port = await self.servers.info(for: server)?.udpEchoPort }
                        return (i, h.healthy, h.responseMs, h.detail, port)
                    }
                    let h = await self.stressProbes.health(of: node)
                    return (i, h.healthy, h.ms, h.detail, nil)
                }
            }
            for await (i, ok, ms, detail, port) in group {
                nodes[i].healthy = ok
                nodes[i].healthLatencyMs = ms
                nodes[i].healthDetail = detail
                if let port { nodes[i].server?.udpEchoPort = port; nodes[i].capabilities.insert(.udpEcho) }
            }
        }
        try Task.checkCancellation()
        let healthy = nodes.filter { $0.healthy == true }
        let plan = StressTestPlan.make(totalSeconds: requested.requestedSeconds, nodes: healthy)
        let total = plan.phases.count
        let skipped = nodes.filter { $0.healthy != true }
        end(.healthCheck, hc, planned: 4, note: skipped.isEmpty ? nil : "略過不健康節點：" + skipped.map(\.name).joined(separator: "、"))
        if plan.throughputNodes.isEmpty { result.notes.append("沒有健康的吞吐量節點（Cloudflare / M-Lab / ChaiNet），下載 / 上傳壓力無法執行。") }

        // Reference path for idle / loaded / recovery latency: first healthy HTTP speed node.
        let primary = plan.throughputNodes.first { $0.provider != .mlab }?.server
        let latencyNode = plan.nodes.first { $0.capabilities.contains(.latency) }
        func referenceProbe() -> any LatencyProbe {
            if let primary { return probes.latencyProbe(for: primary, ipPreference: .automatic) }
            return stressProbes.tcp(host: latencyNode?.host ?? "1.1.1.1", port: 443)
        }
        if let primary {
            result.server = primary
            emit(.serverSelected(primary))
        }
        func sampleReference(seconds: Double, phase: TestPhase) async -> [LatencySample] {
            let probe = referenceProbe()
            defer { Task { await probe.close() } }
            do { try await probe.prepare() } catch { return [] }
            return await LatencySampler.collect(probe: probe, count: count(seconds, pps: 10, minimum: 5), interval: interval(0.1), timeout: 2) {
                emit(.latencySample(phase, $0))
            }
        }

        // 2. Warm-up (connections, radio promotion) — samples discarded.
        hc = begin(.warmUp, total: total)
        _ = await sampleReference(seconds: 3, phase: .preparing)
        end(.warmUp, hc, planned: 3)

        // 3. Idle latency (pre-load).
        emit(.phase(.idleLatency))
        let idlePlanned = plan.phases.first { $0.kind == .idleLatency }?.seconds ?? 5
        hc = begin(.idleLatency, total: total)
        let preSamples = await sampleReference(seconds: idlePlanned, phase: .idleLatency)
        try Task.checkCancellation()
        result.idleSamples = preSamples
        result.idleLatency = LatencyStatistics.compute(from: preSamples)
        end(.idleLatency, hc, planned: idlePlanned)
        emit(.partial(result))

        // 4. Rounds: every throughput node × download / upload, then recovery and cross-server checks.
        var postStats: [LatencyStatistics] = []
        var postSamples: [[LatencySample]] = []
        for round in 1...max(1, plan.rounds) {
            for phase in plan.phases(round: round) where phase.kind == .downloadStress || phase.kind == .uploadStress {
                guard let node = plan.nodes.first(where: { $0.id == phase.nodeID }), let server = node.server else { continue }
                let direction: TransferDirection = phase.kind == .downloadStress ? .download : .upload
                emit(.phase(direction == .download ? .download : .upload))
                hc = begin(phase.kind, round: round, node: node.name, total: total)
                let ndt7 = node.provider == .mlab
                let config = SpeedTestConfiguration(server: server, direction: direction, maxDuration: max(1, phase.seconds * scale),
                                                    autoDuration: nil, fixedStreams: ndt7 ? nil : plan.streams, byteCap: nil)
                let t = try await stressTransfer(config, engine: ndt7 ? self.ndt7 : self.speed, node: node, round: round,
                                                 method: ndt7 ? "NDT7 WebSocket x1" : "HTTP x\(plan.streams)",
                                                 loadedProbe: referenceProbe(), bytes: bytes, emit: emit)
                transfers.append(t)
                end(phase.kind, hc, planned: phase.seconds, round: round, node: node.id, note: t.error)
                result.notes += t.error.map { ["\(node.name) 第 \(round) 輪\(direction == .download ? "下載" : "上傳")：\($0)"] } ?? []
                emit(.partial(result))
            }
            // Cooldown / post-load recovery: how fast queues drain once the load stops.
            let recovery = plan.phases(round: round).first { $0.kind == .postLoadRecovery }?.seconds ?? 4
            hc = begin(.postLoadRecovery, round: round, total: total)
            let post = await sampleReference(seconds: recovery, phase: .idleLatency)
            postSamples.append(post)
            postStats.append(LatencyStatistics.compute(from: post))
            end(.postLoadRecovery, hc, planned: recovery, round: round)

            let cross = plan.phases(round: round).first { $0.kind == .crossServerValidation }?.seconds ?? 3
            emit(.phase(.crossValidation))
            hc = begin(.crossServerValidation, round: round, total: total)
            var checks = await crossValidation.run(endpoints: c.crossValidationEndpoints, probes: count(cross, pps: 10, minimum: 5))
            if let primary, let idle = result.idleLatency {
                checks.insert(EndpointCheck(id: primary.id, name: primary.name, host: primary.host, region: primary.location,
                                            method: .httpPing, statistics: idle, error: nil, isPrimary: true), at: 0)
            }
            result.crossValidation = checks
            end(.crossServerValidation, hc, planned: cross, round: round)
            try Task.checkCancellation()
        }

        // 5. Packet-loss stress: 50 pps ICMP stress probe + independent 5 pps control probes, concurrently.
        emit(.phase(.packetLoss))
        let lossPlanned = plan.phases.first { $0.kind == .packetLossStress }?.seconds ?? 10
        hc = begin(.packetLossStress, total: total)
        let (stressProbe, controls) = await lossStress(plan: plan, seconds: lossPlanned, count: count, interval: interval, emit: emit)
        try Task.checkCancellation()
        end(.packetLossStress, hc, planned: lossPlanned, note: "\(controls.count) 個對照探測")

        // 6. Stability monitoring on the reference path.
        emit(.phase(.monitoring))
        let monPlanned = plan.phases.first { $0.kind == .monitoring }?.seconds ?? 10
        hc = begin(.monitoring, total: total)
        do {
            let probe = referenceProbe()
            let engine = ContinuousPingEngine(networkInfo: networkInfo)
            var samples: [LatencySample] = [], spikes: [LatencySpikeEvent] = [], drops: [NetworkDropEvent] = [], paths: [PathChangeEvent] = []
            for try await event in engine.run(probe: probe, interval: interval(0.5), duration: max(0.01, monPlanned * scale)) {
                switch event {
                case .sample(let s): samples.append(s); emit(.latencySample(.monitoring, s))
                case .spike(let s): spikes.append(s)
                case .dropStarted: break
                case .dropEnded(let d): drops.append(d)
                case .pathChanged(let p): paths.append(p)
                }
            }
            result.monitoring = MonitoringResult(target: probe.targetDescription, intervalSeconds: 0.5, samples: samples,
                                                 statistics: LatencyStatistics.compute(from: samples), spikes: spikes, drops: drops, pathChanges: paths)
        } catch is CancellationError { throw CancellationError() }
        catch { result.notes.append("穩定度監測失敗：\(error.localizedDescription)") }
        end(.monitoring, hc, planned: monPlanned)
        emit(.partial(result))

        // 7. DNS / TCP / TLS / HTTP / QUIC.
        emit(.phase(.dns))
        let dnsPlanned = plan.phases.first { $0.kind == .dnsProtocols }?.seconds ?? 10
        hc = begin(.dnsProtocols, total: total)
        do { result.dns = try await dns.run(resolvers: c.dnsResolvers, domains: DNSBenchmarkEngine.defaultDomains) { _ in } }
        catch is CancellationError { throw CancellationError() }
        catch { result.notes.append("DNS 測試失敗：\(error.localizedDescription)") }
        emit(.phase(.protocols))
        do { result.protocolProbe = try await protocols.run(url: primary?.pingURL() ?? URL(string: "https://www.apple.com")!) }
        catch is CancellationError { throw CancellationError() }
        catch { result.notes.append("協定分析失敗：\(error.localizedDescription)") }
        end(.dnsProtocols, hc, planned: dnsPlanned)
        emit(.partial(result))

        // 8. IPv4 / IPv6.
        emit(.phase(.ipFamilies))
        let ipPlanned = plan.phases.first { $0.kind == .ipFamilies }?.seconds ?? 4
        hc = begin(.ipFamilies, total: total)
        let familyHost = primary?.host ?? latencyNode?.host ?? "www.apple.com"
        result.ipFamilyComparison = await ipFamilies.run(host: familyHost, port: 443, probes: count(ipPlanned, pps: 5, minimum: 5))
        end(.ipFamilies, hc, planned: ipPlanned)

        // 9. Route / MTU.
        let routePlanned = plan.phases.first { $0.kind == .routeMTU }?.seconds ?? 15
        hc = begin(.routeMTU, total: total)
        let icmpTarget = primary?.icmpHost ?? primary?.host ?? "1.1.1.1"
        emit(.phase(.mtu))
        do { result.mtu = try await mtu.run(host: icmpTarget) }
        catch is CancellationError { throw CancellationError() }
        catch { result.notes.append("MTU 測試失敗：\(error.localizedDescription)") }
        emit(.phase(.traceroute))
        do { result.traceroute = try await traceroute.run(host: icmpTarget, maxHops: 30, probesPerHop: 3) { emit(.traceHop($0)) } }
        catch is CancellationError { throw CancellationError() }
        catch { result.notes.append("路由追蹤失敗：\(error.localizedDescription)") }
        end(.routeMTU, hc, planned: routePlanned)
        try Task.checkCancellation()

        // Assemble.
        emit(.phase(.analyzing))
        let summary = StressSummary(plan: plan, configuredSeconds: requested.requestedSeconds, actualSeconds: clock.elapsed, nodes: nodes,
                                    transfers: transfers, phases: records, stressProbe: stressProbe, controlProbes: controls,
                                    preLoadLatency: result.idleLatency, preLoadSamples: preSamples, postLoadLatency: postStats,
                                    postLoadSamples: postSamples, warnings: c.stressWarnings)
        result.stress = summary
        // Representative single-node series for the standard charts (the primary HTTP node's last round).
        let chartNode = plan.throughputNodes.first { $0.provider != .mlab }?.id ?? plan.throughputNodes.first?.id
        let lastDL = transfers.last { $0.nodeID == chartNode && $0.direction == .download && $0.speed != nil }
        let lastUL = transfers.last { $0.nodeID == chartNode && $0.direction == .upload && $0.speed != nil }
        result.download = lastDL?.speed
        result.downloadLoadedLatency = lastDL?.loadedLatency
        result.downloadLoadedSamples = lastDL?.loadedSamples
        result.upload = lastUL?.speed
        result.uploadLoadedLatency = lastUL?.loadedLatency
        result.uploadLoadedSamples = lastUL?.loadedSamples
        if let idle = result.idleLatency {
            result.bufferbloat = BufferbloatCalculator.evaluate(idle: idle, downloadLoaded: result.downloadLoadedLatency,
                                                                uploadLoaded: result.uploadLoadedLatency)
        }
        // Loss shown everywhere = the control probe closest to the multi-probe median, never the stress-only ICMP probe.
        if let median = summary.lossConfirmation.confirmedLossPercent,
           let rep = controls.min(by: { abs($0.lossPercent - median) < abs($1.lossPercent - median) }) {
            result.packetLoss = rep.statistics
            result.packetLossSamples = rep.samples
            result.packetLossMethod = "對照探測 \(rep.name)（\(rep.method)，\(Int(rep.packetsPerSecond)) pps）；判定：\(summary.lossConfirmation.verdict.displayName)"
        }
        result.notes += c.stressWarnings
        result.evaluate(scoreEngine: scoreEngine, diagnostics: diagnostics)
        emit(.phase(.done))
        return result
    }

    /// One transfer with loaded latency on a separate connection. Endpoint errors are returned, not thrown.
    func stressTransfer(_ config: SpeedTestConfiguration, engine: any SpeedTestEngineProtocol, node: StressNode, round: Int, method: String,
                        loadedProbe: any LatencyProbe, bytes: LockedValue<(down: Int64, up: Int64)>,
                        emit: @escaping @Sendable (TestRunEvent) -> Void) async throws -> StressTransferResult {
        let direction = config.direction
        let phase: TestPhase = direction == .download ? .download : .upload
        try? await loadedProbe.prepare()
        let loadedTask = Task {
            var out: [LatencySample] = []
            for await s in LatencySampler.stream(probe: loadedProbe, count: nil, interval: 0.25, timeout: 3) {
                out.append(s)
                emit(.latencySample(phase, s))
            }
            return out
        }
        var speedResult: SpeedResult?
        var failure: String?
        var last: Int64 = 0
        do {
            for try await event in engine.run(config) {
                switch event {
                case .sample(let s):
                    emit(.speedSample(direction, s))
                    let delta = s.cumulativeBytes - last
                    last = s.cumulativeBytes
                    bytes.withLock { if direction == .download { $0.down += delta } else { $0.up += delta } }
                case .streamsChanged(let n): emit(.streams(direction, n))
                case .completed(let r): speedResult = r
                }
            }
        } catch is CancellationError {
            loadedTask.cancel()
            await loadedProbe.close()
            throw CancellationError()
        } catch {
            failure = error.localizedDescription
        }
        loadedTask.cancel()
        let all = await loadedTask.value
        await loadedProbe.close()
        try Task.checkCancellation()
        let ramped = all.filter { $0.offset >= 1.0 }
        let loaded = ramped.isEmpty ? all : ramped
        return StressTransferResult(nodeID: node.id, round: round, direction: direction, method: method, speed: speedResult,
                                    loadedLatency: loaded.isEmpty ? nil : LatencyStatistics.compute(from: loaded), loadedSamples: all,
                                    error: failure ?? (speedResult == nil ? "未完成" : nil))
    }

    /// 50 pps ICMP stress probe plus independent low-rate controls, all at the same time:
    /// ICMP to the primary target, ICMP to two other operators, QUIC (UDP 443), UDP echo (ChaiNet).
    func lossStress(plan: StressTestPlan, seconds: Double, count: (Double, Double, Int) -> Int, interval: (Double) -> Double,
                    emit: @escaping @Sendable (TestRunEvent) -> Void) async -> (LossProbeResult?, [LossProbeResult]) {
        struct Spec: Sendable {
            var id: String, name: String, target: String, method: String, pps: Double, stress: Bool, count: Int, interval: Double
            var probe: any LatencyProbe
        }
        var specs: [Spec] = []
        let primary = plan.throughputNodes.first { $0.provider == .cloudflare }?.server
        let primaryICMP = primary?.icmpHost ?? "1.1.1.1"
        let stressCount = count(seconds, plan.stressPacketsPerSecond, 50)
        let controlCount = count(seconds, plan.controlPacketsPerSecond, LossConfirmation.minimumControlPackets)
        let stressInterval = interval(1 / plan.stressPacketsPerSecond), controlInterval = interval(1 / plan.controlPacketsPerSecond)
        if let p = stressProbes.icmp(host: primaryICMP, packetsPerSecond: plan.stressPacketsPerSecond) {
            specs.append(Spec(id: "stress-icmp-\(primaryICMP)", name: "High-rate ICMP stress probe", target: primaryICMP, method: "icmpEcho",
                              pps: plan.stressPacketsPerSecond, stress: true, count: stressCount, interval: stressInterval, probe: p))
        }
        if let p = stressProbes.icmp(host: primaryICMP, packetsPerSecond: plan.controlPacketsPerSecond) {
            specs.append(Spec(id: "control-icmp-\(primaryICMP)", name: "Low-rate ICMP control (primary)", target: primaryICMP, method: "icmpEcho",
                              pps: plan.controlPacketsPerSecond, stress: false, count: controlCount, interval: controlInterval, probe: p))
        }
        for node in plan.latencyOnlyNodes where node.capabilities.contains(.loss) {
            if let p = stressProbes.icmp(host: node.host, packetsPerSecond: plan.controlPacketsPerSecond) {
                specs.append(Spec(id: "control-icmp-\(node.id)", name: "Low-rate ICMP control (\(node.name))", target: node.host, method: "icmpEcho",
                                  pps: plan.controlPacketsPerSecond, stress: false, count: controlCount, interval: controlInterval, probe: p))
            }
        }
        if let host = primary?.host {
            specs.append(Spec(id: "control-quic-\(host)", name: "QUIC / UDP 443 handshake control", target: host, method: "quicHandshake",
                              pps: plan.controlPacketsPerSecond, stress: false, count: controlCount, interval: controlInterval,
                              probe: stressProbes.quic(host: host)))
        }
        for node in plan.throughputNodes where node.provider == .chainet {
            if let server = node.server, let port = server.udpEchoPort {
                specs.append(Spec(id: "control-udp-\(node.id)", name: "UDP echo control (\(node.name))", target: "\(server.host):\(port)",
                                  method: "udpEcho", pps: plan.controlPacketsPerSecond, stress: false, count: controlCount,
                                  interval: controlInterval, probe: stressProbes.udpEcho(host: server.host, port: port)))
            }
        }
        let results = await withTaskGroup(of: LossProbeResult?.self) { group in
            for spec in specs {
                group.addTask {
                    do { try await spec.probe.prepare() } catch { return nil }
                    let samples = await LatencySampler.collect(probe: spec.probe, count: spec.count, interval: spec.interval, timeout: 1) {
                        if spec.stress { emit(.latencySample(.packetLoss, $0)) }
                    }
                    await spec.probe.close()
                    return LossProbeResult(id: spec.id, name: spec.name, target: spec.target, method: spec.method,
                                           packetsPerSecond: spec.pps, isStressProbe: spec.stress, samples: samples)
                }
            }
            var out: [LossProbeResult] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        let ordered = specs.compactMap { s in results.first { $0.id == s.id } }
        return (ordered.first { $0.isStressProbe }, ordered.filter { !$0.isStressProbe })
    }
}
