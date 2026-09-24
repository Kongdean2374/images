import Foundation
import ChaiNetCore

public enum TestPhase: String, Sendable, Hashable, CaseIterable {
    case preparing, selectingServer, idleLatency, packetLoss, download, upload, multiServer, monitoring
    case dns, protocols, ipFamilies, crossValidation, interfaceCompare, mtu, traceroute, analyzing, done

    public var displayName: String {
        switch self {
        case .preparing: "準備中"
        case .selectingServer: "選擇伺服器"
        case .idleLatency: "Ping"
        case .packetLoss: "封包遺失 / 抖動"
        case .download: "下載"
        case .upload: "上傳"
        case .multiServer: "多伺服器比較"
        case .monitoring: "穩定度監測"
        case .dns: "DNS"
        case .protocols: "HTTP / TLS / QUIC"
        case .ipFamilies: "IPv4 / IPv6"
        case .crossValidation: "交叉驗證"
        case .interfaceCompare: "介面比較"
        case .mtu: "MTU"
        case .traceroute: "路由追蹤"
        case .analyzing: "分析中"
        case .done: "完成"
        }
    }
}

public struct TestRunConfiguration: Sendable {
    public var kind: TestKind
    public var items: Set<TestItem>
    public var candidateServers: [ServerDescriptor]
    /// Use this server instead of auto-selection.
    public var fixedServer: ServerDescriptor?
    public var settings: AppSettings
    public var onCellular: Bool
    public var idleProbeCount: Int = 20
    /// Loss-probe schedule; quality tests override (gaming 50 pps, voice 50 pps × 172 B).
    public var lossProbeInterval: Double = 0.05
    public var lossProbeCount: Int = 100
    public var lossPayloadBytes: Int = 64
    public var monitoringSeconds: Double = 60
    public var crossValidationProbes: Int = 30
    public var ipFamilyProbes: Int = 15
    public var interfaceProbes: Int = 15
    /// Extreme Full Test: per-phase times come from this plan (overrides `applyTiming`).
    public var fullTestPlan: FullTestPlan?
    /// Download / upload duration override (seconds, per direction per server).
    public var throughputSecondsOverride: Double?
    /// Extra servers measured with the same server-dependent items (multi-server test).
    public var additionalServers: [ServerDescriptor] = []
    /// Add this many extra servers automatically from the latency ranking.
    public var autoAdditionalServerCount: Int = 0
    public var crossValidationEndpoints: [ValidationEndpoint] = ValidationEndpoint.defaults
    public var dnsResolvers: [DNSResolverDescriptor] = DNSResolverDescriptor.defaults
    public var tracerouteHost: String?
    /// Extreme Stress Test plan (kind `.extremeStressTest`).
    public var stressPlan: StressTestPlan?
    /// Pre-start warnings (Low Data Mode, metered, VPN…) — recorded, never reduce intensity.
    public var stressWarnings: [String] = []
    /// Mobile-data safety limits (hard cap / per-direction caps / warning).
    public var stressDataLimits: StressDataLimits = .unlimited
    /// Multiplies phase durations / probe counts (tests only; 1 in the app).
    public var stressTimeScale: Double = 1

    public init(kind: TestKind, items: Set<TestItem>, candidateServers: [ServerDescriptor], fixedServer: ServerDescriptor? = nil,
                settings: AppSettings, onCellular: Bool) {
        self.kind = kind
        self.items = items
        self.candidateServers = candidateServers
        self.fixedServer = fixedServer
        self.settings = settings
        self.onCellular = onCellular
    }

    /// Applies the test-duration setting to every time-based phase (see `PhaseTiming`).
    public mutating func applyTiming() {
        let autoLoss = lossProbeCount
        let t = PhaseTiming.make(settings.testDuration, lossInterval: lossProbeInterval, autoLossProbes: autoLoss)
        idleProbeCount = t.idleProbeCount
        lossProbeCount = t.lossProbeCount
        crossValidationProbes = t.crossValidationProbes
        ipFamilyProbes = t.ipFamilyProbes
        interfaceProbes = t.interfaceProbes
        monitoringSeconds = t.monitoringSeconds
    }

    /// Extreme Full Test: every item, maximum load, times from `plan`.
    public static func extreme(plan: FullTestPlan, servers: [ServerDescriptor], fixedServer: ServerDescriptor?, settings: AppSettings,
                               onCellular: Bool) -> TestRunConfiguration {
        var s = settings
        s.trafficUsage = .unlimited
        if plan.forceMaxStreams { s.parallelConnections = .sixteen }
        s.autoCrossValidation = true
        var c = TestRunConfiguration(kind: .extremeFullTest, items: FullTestPlan.allItems, candidateServers: servers,
                                     fixedServer: fixedServer, settings: s, onCellular: onCellular)
        c.fullTestPlan = plan
        c.idleProbeCount = max(1, Int(plan.idleSeconds / 0.1))
        c.lossProbeInterval = 0.02                       // 50 pps, like a game / VoIP stream
        c.lossProbeCount = max(1, Int(plan.lossSeconds / 0.02))
        c.throughputSecondsOverride = plan.throughputSeconds
        c.monitoringSeconds = plan.monitoringSeconds
        c.crossValidationProbes = max(1, Int(plan.crossValidationSeconds / 0.1))
        c.ipFamilyProbes = max(1, Int(plan.ipFamilySeconds / 0.2))
        c.interfaceProbes = max(1, Int(plan.interfaceSeconds / 0.2))
        return c
    }

    /// Quality-test presets.
    public static func quality(_ kind: TestKind, servers: [ServerDescriptor], fixedServer: ServerDescriptor?, settings: AppSettings, onCellular: Bool) -> TestRunConfiguration {
        var c: TestRunConfiguration
        switch kind {
        case .gaming:
            // .crossValidation: verdicts use the best healthy regional path, not a single ICMP target.
            c = TestRunConfiguration(kind: kind, items: [.ping, .jitter, .packetLoss, .burstLoss, .latencySpikes, .bufferbloat, .crossValidation],
                                     candidateServers: servers, fixedServer: fixedServer, settings: settings, onCellular: onCellular)
            c.lossProbeInterval = 0.02; c.lossProbeCount = 750; c.lossPayloadBytes = 64          // 50 pps × 15 s
        case .voice:
            c = TestRunConfiguration(kind: kind, items: [.ping, .jitter, .packetLoss, .burstLoss, .upload],
                                     candidateServers: servers, fixedServer: fixedServer, settings: settings, onCellular: onCellular)
            c.lossProbeInterval = 0.02; c.lossProbeCount = 750; c.lossPayloadBytes = 172         // G.711 20 ms RTP frame
        case .streaming:
            c = TestRunConfiguration(kind: kind, items: [.ping, .download, .bufferbloat, .http],
                                     candidateServers: servers, fixedServer: fixedServer, settings: settings, onCellular: onCellular)
        case .obsUpload:
            c = TestRunConfiguration(kind: kind, items: [.ping, .upload, .bufferbloat, .packetLoss],
                                     candidateServers: servers, fixedServer: fixedServer, settings: settings, onCellular: onCellular)
        default:
            c = TestRunConfiguration(kind: kind, items: TestProfile.quickSpeed.items, candidateServers: servers, fixedServer: fixedServer,
                                     settings: settings, onCellular: onCellular)
        }
        return c
    }
}

public enum TestRunEvent: Sendable {
    case phase(TestPhase)
    case network(NetworkSnapshot)
    case serverSelected(ServerDescriptor)
    case latencySample(TestPhase, LatencySample)
    case speedSample(TransferDirection, SpeedSample)
    case streams(TransferDirection, Int)
    case traceHop(TracerouteHop)
    case partial(TestResult)
    case completed(TestResult)
    /// Extreme Stress Test phase / round / node and running traffic totals.
    case stressProgress(StressProgress)
}

public protocol TestRunnerProtocol: Sendable {
    func run(_ configuration: TestRunConfiguration) -> AsyncThrowingStream<TestRunEvent, Error>
}

/// Executes a set of `TestItem`s against one server and assembles a `TestResult`.
///
/// Order (idle before load so load can't disturb idle measurements):
/// network snapshot → server → idle latency → loss/jitter probe → download (+ loaded latency)
/// → upload (+ loaded latency) → monitoring → DNS → HTTP/TLS/QUIC → IPv4/IPv6 → cross-validation
/// → interface compare → MTU → traceroute → scoring / diagnostics / quality verdicts.
///
/// After every phase a `.partial` result is emitted, so a stopped test keeps what it measured.
public struct TestRunner: TestRunnerProtocol {
    public var speed: any SpeedTestEngineProtocol
    public var dns: any DNSBenchmarkEngineProtocol
    public var protocols: any ProtocolProbeEngineProtocol
    public var traceroute: any TracerouteEngineProtocol
    public var mtu: any MTUDiscoveryEngineProtocol
    public var crossValidation: any CrossValidationEngineProtocol
    public var ipFamilies: any IPFamilyCompareEngineProtocol
    public var interfaces: any InterfaceCompareEngineProtocol
    public var servers: any ServerDirectoryProtocol
    public var networkInfo: any NetworkInfoProviding
    public var probes: any LatencyProbeFactory
    public var scoreEngine: any ScoreEngineProtocol
    public var diagnostics: any DiagnosticsEngineProtocol
    /// M-Lab NDT7 engine (stress test).
    public var ndt7: any SpeedTestEngineProtocol
    public var stressProbes: any StressProbeFactory

    public init(speed: any SpeedTestEngineProtocol = URLSessionSpeedTestEngine(),
                dns: any DNSBenchmarkEngineProtocol = DNSBenchmarkEngine(),
                protocols: any ProtocolProbeEngineProtocol = ProtocolProbeEngine(),
                traceroute: any TracerouteEngineProtocol = ICMPTracerouteEngine(),
                mtu: any MTUDiscoveryEngineProtocol = ICMPMTUDiscoveryEngine(),
                crossValidation: any CrossValidationEngineProtocol = CrossValidationEngine(),
                ipFamilies: any IPFamilyCompareEngineProtocol = IPFamilyCompareEngine(),
                interfaces: any InterfaceCompareEngineProtocol = InterfaceCompareEngine(),
                servers: any ServerDirectoryProtocol = ServerDirectory(),
                networkInfo: any NetworkInfoProviding = NetworkInfoProvider(),
                probes: any LatencyProbeFactory = DefaultLatencyProbeFactory(),
                scoreEngine: any ScoreEngineProtocol = ScoreEngine(),
                diagnostics: any DiagnosticsEngineProtocol = DiagnosticsEngine(),
                ndt7: any SpeedTestEngineProtocol = NDT7SpeedTestEngine(),
                stressProbes: any StressProbeFactory = DefaultStressProbeFactory()) {
        self.speed = speed
        self.dns = dns
        self.protocols = protocols
        self.traceroute = traceroute
        self.mtu = mtu
        self.crossValidation = crossValidation
        self.ipFamilies = ipFamilies
        self.interfaces = interfaces
        self.servers = servers
        self.networkInfo = networkInfo
        self.probes = probes
        self.scoreEngine = scoreEngine
        self.diagnostics = diagnostics
        self.ndt7 = ndt7
        self.stressProbes = stressProbes
    }

    public func run(_ configuration: TestRunConfiguration) -> AsyncThrowingStream<TestRunEvent, Error> {
        let runner = self
        return makeCancellableStream { continuation in
            let emit: @Sendable (TestRunEvent) -> Void = { continuation.yield($0) }
            let result: TestResult
            if configuration.kind == .extremeStressTest, let plan = configuration.stressPlan {
                result = try await runner.executeStress(configuration, plan: plan, emit: emit)
            } else {
                result = try await runner.execute(configuration, emit: emit)
            }
            continuation.yield(.completed(result))
        }
    }

    // MARK: - Execution

    func execute(_ c: TestRunConfiguration, emit: @escaping @Sendable (TestRunEvent) -> Void) async throws -> TestResult {
        let items = c.items
        let needsLatency = !items.isDisjoint(with: [.ping, .jitter, .download, .upload, .bufferbloat])
        let needsLoss = !items.isDisjoint(with: [.packetLoss, .burstLoss, .latencySpikes, .jitter])
        let settings = c.settings

        emit(.phase(.preparing))
        let snapshot = await networkInfo.snapshot(includePublicIP: true)
        emit(.network(snapshot))
        guard snapshot.status == .satisfied else { throw EngineError.noNetwork }
        var result = TestResult(kind: c.kind, network: snapshot)
        result.ipFamilyPreference = settings.ipPreference
        try Task.checkCancellation()

        // Server
        emit(.phase(.selectingServer))
        var server: ServerDescriptor
        var extraServers = c.additionalServers
        if let fixed = c.fixedServer, c.autoAdditionalServerCount == 0 {
            server = fixed
        } else {
            let ranking = await servers.rank(c.candidateServers)
            let reachable = ranking.filter { $0.medianMs != nil }.map(\.server)
            guard let best = c.fixedServer ?? reachable.first ?? c.candidateServers.first else {
                throw EngineError.server("沒有可用的測速伺服器")
            }
            server = best
            if c.autoAdditionalServerCount > 0 {
                extraServers += reachable.filter { s in s.id != best.id && !extraServers.contains { $0.id == s.id } }
                    .prefix(c.autoAdditionalServerCount)
                if extraServers.isEmpty {
                    result.notes.append("自動多伺服器：目前只有 1 台可用伺服器；加入自架伺服器即可比較多台。")
                }
            }
        }
        extraServers.removeAll { $0.id == server.id }
        if let info = await servers.info(for: server) {
            result.serverInfo = info
            if server.udpEchoPort == nil { server.udpEchoPort = info.udpEchoPort }
        }
        result.serverHealth = await servers.health(for: server)
        result.server = server
        emit(.serverSelected(server))
        emit(.partial(result))
        try Task.checkCancellation()

        // Idle latency
        if needsLatency {
            emit(.phase(.idleLatency))
            let probe = probes.latencyProbe(for: server, ipPreference: settings.ipPreference)
            try await probe.prepare()
            let samples = await LatencySampler.collect(probe: probe, count: c.idleProbeCount, interval: 0.1, timeout: 2) {
                emit(.latencySample(.idleLatency, $0))
            }
            await probe.close()
            try Task.checkCancellation()
            result.idleSamples = samples
            result.idleLatency = LatencyStatistics.compute(from: samples)
            emit(.partial(result))
        }

        // Loss / jitter / burst / spikes
        if needsLoss {
            emit(.phase(.packetLoss))
            if let pair = probes.lossProbe(for: server, payloadSize: c.lossPayloadBytes, ipPreference: settings.ipPreference) {
                let probe = pair.probe, method = pair.method
                do {
                    try await probe.prepare()
                    let count = items.contains(.latencySpikes) && c.settings.testDuration == .auto && c.fullTestPlan == nil
                        ? max(c.lossProbeCount, 200) : c.lossProbeCount
                    let samples = await LatencySampler.collect(probe: probe, count: count, interval: c.lossProbeInterval, timeout: 1) {
                        emit(.latencySample(.packetLoss, $0))
                    }
                    await probe.close()
                    try Task.checkCancellation()
                    let stats = LatencyStatistics.compute(from: samples)
                    result.packetLoss = stats
                    result.packetLossSamples = samples
                    result.packetLossMethod = "\(method)，\(count) 個封包，每 \(Int(c.lossProbeInterval * 1000)) ms"
                    if items.contains(.latencySpikes) {
                        result.monitoring = Self.monitoringSummary(target: probe.targetDescription, interval: c.lossProbeInterval, samples: samples)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await probe.close()
                    result.notes.append("封包遺失測試失敗：\(error.localizedDescription)")
                }
            } else {
                result.notes.append("此伺服器沒有 UDP echo，且無可用的 ICMP 目標；封包遺失無法量測（TCP 會以重傳隱藏遺失）。")
            }
            emit(.partial(result))
        }

        // Throughput
        let maxDuration = c.throughputSecondsOverride ?? settings.effectiveMaxDuration(onCellular: c.onCellular)
        let auto: AutoDurationPolicy? = settings.testDuration == .auto && c.throughputSecondsOverride == nil ? AutoDurationPolicy() : nil
        result.fullTestPlan = c.fullTestPlan
        for direction in [TransferDirection.download, .upload] {
            let wanted = direction == .download
                ? (items.contains(.download) || (items.contains(.bufferbloat) && c.kind != .obsUpload && c.kind != .voice))
                : (items.contains(.upload) || (items.contains(.bufferbloat) && c.kind != .streaming && c.kind != .gaming))
            guard wanted else { continue }
            emit(.phase(direction == .download ? .download : .upload))
            let config = SpeedTestConfiguration(server: server, direction: direction, maxDuration: maxDuration, autoDuration: auto,
                                                fixedStreams: settings.parallelConnections.fixedCount,
                                                byteCap: settings.transferByteCap(onCellular: c.onCellular))
            let (speedResult, measuredLoaded, loadedSamples) = try await runThroughput(config, server: server, measureLoaded: needsLatency,
                                                                                       ipPreference: settings.ipPreference, emit: emit)
            // Loaded latency only means something if the transfer actually loaded the link.
            var loaded = measuredLoaded
            if let v = speedResult.validity, !v.valid {
                loaded = nil
                result.notes.append("\(direction == .download ? "下載" : "上傳")傳輸無效（\(v.reason?.rawValue ?? "invalid")：\(v.detail ?? "")），不列入速度、穩定度與 Bufferbloat 計算。")
            }
            if direction == .download {
                result.download = speedResult
                result.downloadLoadedLatency = loaded
                result.downloadLoadedSamples = loadedSamples
            } else {
                result.upload = speedResult
                result.uploadLoadedLatency = loaded
                result.uploadLoadedSamples = loadedSamples
            }
            emit(.partial(result))
        }
        if let idle = result.idleLatency {
            result.bufferbloat = BufferbloatCalculator.evaluate(idle: idle, downloadLoaded: result.downloadLoadedLatency, uploadLoaded: result.uploadLoadedLatency)
        }

        // Multi-server: repeat the server-dependent items on every extra server.
        if !extraServers.isEmpty && !items.isDisjoint(with: [.ping, .jitter, .packetLoss, .burstLoss, .download, .upload]) {
            emit(.phase(.multiServer))
            var runs: [ServerRun] = []
            for extra in extraServers {
                try Task.checkCancellation()
                runs.append(try await measure(extra, c, needsLatency: needsLatency, needsLoss: needsLoss, maxDuration: maxDuration, auto: auto, emit: emit))
                result.serverRuns = runs
                emit(.partial(result))
            }
        }

        // Monitoring (drop detection)
        if items.contains(.continuousPing) || items.contains(.dropMonitor) {
            emit(.phase(.monitoring))
            let pair = probes.lossProbe(for: server, payloadSize: 64, ipPreference: settings.ipPreference)
            let probe = pair?.probe ?? probes.latencyProbe(for: server, ipPreference: settings.ipPreference)
            let engine = ContinuousPingEngine(networkInfo: networkInfo)
            var samples: [LatencySample] = [], spikes: [LatencySpikeEvent] = [], drops: [NetworkDropEvent] = [], paths: [PathChangeEvent] = []
            for try await event in engine.run(probe: probe, interval: 0.5, duration: c.monitoringSeconds) {
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
            emit(.partial(result))
        }

        if items.contains(.dns) {
            emit(.phase(.dns))
            result.dns = try await dns.run(resolvers: c.dnsResolvers, domains: DNSBenchmarkEngine.defaultDomains) { _ in }
            emit(.partial(result))
        }
        if !items.isDisjoint(with: [.http, .tls, .quic]) {
            emit(.phase(.protocols))
            result.protocolProbe = try await protocols.run(url: server.pingURL())
            emit(.partial(result))
        }
        if items.contains(.ipFamilies) {
            emit(.phase(.ipFamilies))
            result.ipFamilyComparison = await ipFamilies.run(host: server.host, port: UInt16(server.baseURL.port ?? 443), probes: c.ipFamilyProbes)
            emit(.partial(result))
        }
        try Task.checkCancellation()

        // Cross-validation: explicit, or automatic when the primary server looks abnormal.
        let primaryStats = result.packetLoss ?? result.idleLatency
        let primaryAbnormal = primaryStats.map { TestHealthEvaluator.assess($0, error: nil).isDegraded } ?? false
        if items.contains(.crossValidation) || (settings.autoCrossValidation && primaryAbnormal) {
            emit(.phase(.crossValidation))
            if primaryAbnormal && !items.contains(.crossValidation) {
                result.notes.append("主要伺服器出現異常，已自動對 \(c.crossValidationEndpoints.count) 個獨立端點進行交叉驗證。")
            }
            var checks = await crossValidation.run(endpoints: c.crossValidationEndpoints, probes: c.crossValidationProbes)
            if let primaryStats {
                checks.insert(EndpointCheck(id: server.id, name: server.name, host: server.host, region: server.location,
                                            method: result.packetLoss != nil ? (server.udpEchoPort != nil ? .udpEcho : .icmpEcho) : .httpPing,
                                            statistics: primaryStats, error: nil, isPrimary: true), at: 0)
            }
            result.crossValidation = checks
            emit(.partial(result))
        }
        if items.contains(.interfaceCompare) {
            emit(.phase(.interfaceCompare))
            result.interfaceCompare = await interfaces.run(host: server.host, interfaces: [.wifi, .cellular], probes: c.interfaceProbes)
            emit(.partial(result))
        }
        let icmpTarget = c.tracerouteHost ?? server.icmpHost ?? server.host
        if items.contains(.mtu) {
            emit(.phase(.mtu))
            do { result.mtu = try await mtu.run(host: icmpTarget) }
            catch is CancellationError { throw CancellationError() }
            catch { result.notes.append("MTU 測試失敗：\(error.localizedDescription)") }
            emit(.partial(result))
        }
        if items.contains(.traceroute) {
            emit(.phase(.traceroute))
            do { result.traceroute = try await traceroute.run(host: icmpTarget, maxHops: 30, probesPerHop: 3) { emit(.traceHop($0)) } }
            catch is CancellationError { throw CancellationError() }
            catch { result.notes.append("路由追蹤失敗：\(error.localizedDescription)") }
            emit(.partial(result))
        }
        try Task.checkCancellation()

        emit(.phase(.analyzing))
        result.evaluate(scoreEngine: scoreEngine, diagnostics: diagnostics)
        applyQualityVerdicts(&result, c)
        if settings.ipPreference != .automatic {
            result.notes.append("IP 協定限制（\(settings.ipPreference.displayName)）套用於延遲與遺失測試；下載 / 上傳由系統選擇（URLSession 無法指定 IP 版本）。")
        }
        emit(.phase(.done))
        return result
    }

    /// Server-dependent measurements on one additional server.
    func measure(_ server: ServerDescriptor, _ c: TestRunConfiguration, needsLatency: Bool, needsLoss: Bool, maxDuration: Double,
                 auto: AutoDurationPolicy?, emit: @escaping @Sendable (TestRunEvent) -> Void) async throws -> ServerRun {
        var run = ServerRun(server: server)
        var target = server
        if target.udpEchoPort == nil, let info = await servers.info(for: server) { target.udpEchoPort = info.udpEchoPort }
        if needsLatency {
            let probe = probes.latencyProbe(for: target, ipPreference: c.settings.ipPreference)
            do {
                try await probe.prepare()
                run.idleLatency = LatencyStatistics.compute(from: await LatencySampler.collect(probe: probe, count: c.idleProbeCount, interval: 0.1, timeout: 2))
            } catch is CancellationError { await probe.close(); throw CancellationError() }
            catch { run.error = "延遲：\(error.localizedDescription)" }
            await probe.close()
        }
        if needsLoss, let pair = probes.lossProbe(for: target, payloadSize: c.lossPayloadBytes, ipPreference: c.settings.ipPreference) {
            do {
                try await pair.probe.prepare()
                run.packetLoss = LatencyStatistics.compute(from: await LatencySampler.collect(probe: pair.probe, count: c.lossProbeCount,
                                                                                               interval: c.lossProbeInterval, timeout: 1))
                run.packetLossMethod = pair.method
            } catch is CancellationError { await pair.probe.close(); throw CancellationError() }
            catch { run.error = "遺失：\(error.localizedDescription)" }
            await pair.probe.close()
        }
        try Task.checkCancellation()
        for direction in [TransferDirection.download, .upload] where c.items.contains(direction == .download ? .download : .upload) {
            let config = SpeedTestConfiguration(server: target, direction: direction, maxDuration: maxDuration, autoDuration: auto,
                                                fixedStreams: c.settings.parallelConnections.fixedCount,
                                                byteCap: c.settings.transferByteCap(onCellular: c.onCellular))
            do {
                var speedResult: SpeedResult?
                for try await event in speed.run(config) {
                    if case .completed(let r) = event { speedResult = r }
                }
                if direction == .download { run.download = speedResult } else { run.upload = speedResult }
            } catch is CancellationError { throw CancellationError() }
            catch { run.error = "\(direction == .download ? "下載" : "上傳")：\(error.localizedDescription)" }
        }
        return run
    }

    /// Runs one throughput direction while measuring latency on a separate connection.
    func runThroughput(_ config: SpeedTestConfiguration, server: ServerDescriptor, measureLoaded: Bool, ipPreference: IPFamilyPreference,
                       emit: @escaping @Sendable (TestRunEvent) -> Void) async throws -> (SpeedResult, LatencyStatistics?, [LatencySample]) {
        let direction = config.direction
        let phase: TestPhase = direction == .download ? .download : .upload
        let loadedProbe: (any LatencyProbe)? = measureLoaded ? probes.latencyProbe(for: server, ipPreference: ipPreference) : nil
        try? await loadedProbe?.prepare()

        let loadedTask: Task<[LatencySample], Never>? = loadedProbe.map { probe in
            Task {
                var out: [LatencySample] = []
                for await s in LatencySampler.stream(probe: probe, count: nil, interval: 0.25, timeout: 3) {
                    out.append(s)
                    emit(.latencySample(phase, s))
                }
                return out
            }
        }

        var speedResult: SpeedResult?
        do {
            for try await event in speed.run(config) {
                switch event {
                case .sample(let s): emit(.speedSample(direction, s))
                case .streamsChanged(let n): emit(.streams(direction, n))
                case .completed(let r): speedResult = r
                }
            }
        } catch {
            loadedTask?.cancel()
            await loadedProbe?.close()
            throw error
        }
        loadedTask?.cancel()
        // Samples from the first second (TCP slow start, link not yet saturated) are excluded
        // when later samples exist.
        let allLoaded = await loadedTask?.value ?? []
        let rampedUp = allLoaded.filter { $0.offset >= 1.0 }
        let loadedSamples = rampedUp.isEmpty ? allLoaded : rampedUp
        await loadedProbe?.close()
        try Task.checkCancellation()
        guard let speedResult else { throw EngineError.invalidResponse("測速未完成") }
        return (speedResult, loadedSamples.isEmpty ? nil : LatencyStatistics.compute(from: loadedSamples), allLoaded)
    }

    static func monitoringSummary(target: String, interval: Double, samples: [LatencySample]) -> MonitoringResult {
        var spikes = LatencySpikeDetector()
        var drops = NetworkDropDetector()
        var spikeEvents: [LatencySpikeEvent] = []
        var dropEvents: [NetworkDropEvent] = []
        for s in samples.sorted(by: { $0.sequence < $1.sequence }) {
            if let rtt = s.rttMs, let e = spikes.ingest(sequence: s.sequence, offset: s.offset, rttMs: rtt) { spikeEvents.append(e) }
            if case .ended(let d)? = drops.ingest(s) { dropEvents.append(d) }
        }
        return MonitoringResult(target: target, intervalSeconds: interval, samples: samples, statistics: LatencyStatistics.compute(from: samples),
                                spikes: spikeEvents, drops: dropEvents, pathChanges: [])
    }

    func applyQualityVerdicts(_ r: inout TestResult, _ c: TestRunConfiguration) {
        if c.kind == .extremeFullTest {
            // Every scenario verdict from the same, complete data set.
            for kind in [TestKind.gaming, .voice, .streaming, .obsUpload] {
                var sub = c
                sub.kind = kind
                applyQualityVerdicts(&r, sub)
            }
            return
        }
        switch c.kind {
        case .gaming:
            if let idle = r.packetLoss ?? r.idleLatency {
                let alternatives = (r.crossValidation ?? []).filter { !$0.isPrimary }.compactMap { e in
                    e.statistics.map { GamingPathCandidate(name: e.name, host: e.host, method: e.method.rawValue, statistics: $0, isPrimary: false) }
                }
                r.gaming = GamingQualityCalculator.evaluate(idle: idle, loaded: r.downloadLoadedLatency, spikes: r.monitoring?.spikes ?? [],
                                                            packetsPerSecond: 1 / c.lossProbeInterval, downloadMbps: r.download?.summary.averageMbps,
                                                            score: r.scores.gaming, alternatives: alternatives,
                                                            primaryName: r.server?.name ?? "主要伺服器")
            }
        case .voice:
            if let stats = r.packetLoss ?? r.idleLatency {
                r.voice = VoiceQualityCalculator.evaluate(stats, packetsPerSecond: 1 / c.lossProbeInterval, payloadBytes: c.lossPayloadBytes)
            }
        case .streaming:
            if let dl = r.download {
                r.streaming = StreamingQualityCalculator.evaluate(download: dl, ttfbMs: r.protocolProbe?.http?.ttfbMs, score: r.scores.streaming)
            }
        case .obsUpload:
            if let ul = r.upload {
                r.obs = OBSSuitabilityCalculator.evaluate(upload: ul, idleLatency: r.idleLatency, uploadLoadedLatency: r.uploadLoadedLatency,
                                                          score: r.scores.upload)
            }
        default:
            break
        }
    }
}
