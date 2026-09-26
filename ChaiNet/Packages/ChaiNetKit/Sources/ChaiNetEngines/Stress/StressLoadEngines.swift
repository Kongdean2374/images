import Foundation
import ChaiNetCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Environment recorder

/// Samples thermal state, battery, Low Power Mode, interface and radio technology during a stress
/// test. Only public APIs; anything the platform does not expose stays nil ("unavailable").
public final class EnvironmentRecorder: @unchecked Sendable {
    private let store = LockedValue<[EnvironmentSample]>([])
    private let clock: Stopwatch
    private let scale: Double
    private let networkInfo: (any NetworkInfoProviding)?
    private var task: Task<Void, Never>?

    public init(clock: Stopwatch, scale: Double = 1, networkInfo: (any NetworkInfoProviding)?) {
        self.clock = clock
        self.scale = scale
        self.networkInfo = networkInfo
    }

    public var latest: EnvironmentSample? { store.current.last }

    public func start(interval: Double = 5) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce()
                try? await Task.sleep(for: .seconds(max(0.01, interval * (self?.scale ?? 1))))
            }
        }
    }

    public func sampleOnce() async {
        let thermal = Self.thermalState()
        let battery = await Self.battery()
        var interface: String?, radio: String?
        if let networkInfo {
            let snap = await networkInfo.snapshot(includePublicIP: false)
            interface = snap.primaryInterface.rawValue
            if let c = snap.cellular, case .available(let rat) = c.radioTechnology { radio = rat.rawValue }
        }
        let sample = EnvironmentSample(offset: clock.elapsed / scale, thermalState: thermal, batteryPercent: battery.level,
                                       batteryState: battery.state, lowPowerMode: Self.lowPowerMode(), interface: interface, radioTechnology: radio)
        store.withLock { $0.append(sample) }
    }

    /// Synchronous cancel (e.g. from `defer` when the test is cancelled).
    public func cancel() { task?.cancel() }

    public func stop() async -> EnvironmentRecord {
        task?.cancel()
        await sampleOnce()
        return EnvironmentRecord(samples: store.current)
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func lowPowerMode() -> Bool? {
        #if os(iOS) || os(macOS)
        return ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        return nil
        #endif
    }

    static func battery() async -> (level: Double?, state: String?) {
        #if canImport(UIKit) && !os(watchOS)
        return await MainActor.run {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let level = device.batteryLevel
            let state: String
            switch device.batteryState {
            case .charging: state = "charging"
            case .full: state = "full"
            case .unplugged: state = "unplugged"
            default: state = "unknown"
            }
            return (level < 0 ? nil : Double(level) * 100, state)
        }
        #else
        return (nil, nil)
        #endif
    }
}

// MARK: - Continuous monitor

/// One low-rate control probe (fixed target, same method) running through the entire stress test.
/// Phases announce themselves with `enter`; every sample is tagged with the current phase and
/// load, so per-phase windows are slices of one series (no second monitoring engine).
public final class ContinuousLatencyMonitor: @unchecked Sendable {
    struct Context: Sendable {
        var phaseID = "start"
        var phase = "start"
        var loadType = LoadType.idle
        var phaseStart = 0.0
        var download: Double?
        var upload: Double?
    }

    public let descriptor: ProbeDescriptor?
    public let intervalSeconds: Double
    private let probe: (any LatencyProbe)?
    private let clock: Stopwatch
    /// Test time scale (1 in the app); reported offsets are divided by it.
    private let scale: Double
    private let context = LockedValue(Context())
    private let store = LockedValue<[MonitorSample]>([])
    private let environment: EnvironmentRecorder?
    private var task: Task<Void, Never>?

    public init(probe: (any LatencyProbe)?, descriptor: ProbeDescriptor?, intervalSeconds: Double = 0.25, clock: Stopwatch,
                scale: Double = 1, environment: EnvironmentRecorder? = nil) {
        self.probe = probe
        self.descriptor = descriptor
        self.intervalSeconds = intervalSeconds
        self.clock = clock
        self.scale = scale
        self.environment = environment
    }

    /// Seconds on the monitor clock (scaled test time).
    public var now: Double { clock.elapsed }

    public func start() {
        guard let probe, task == nil else { return }
        let interval = max(0.002, intervalSeconds * scale)
        task = Task { [weak self] in
            do { try await probe.prepare() } catch { return }
            guard let startOffset = self?.clock.elapsed else { return }
            for await s in LatencySampler.stream(probe: probe, count: nil, interval: interval, timeout: 2) {
                self?.record(s, startOffset: startOffset)
            }
        }
    }

    private func record(_ s: LatencySample, startOffset: Double) {
        let ctx = context.current
        let g = startOffset + s.offset
        let env = environment?.latest
        store.withLock {
            $0.append(MonitorSample(globalOffset: g / scale, phaseID: ctx.phaseID, phase: ctx.phase, phaseOffset: max(0, g - ctx.phaseStart) / scale,
                                    rttMs: s.rttMs, loadType: ctx.loadType, downloadMbps: ctx.download, uploadMbps: ctx.upload,
                                    thermalState: env?.thermalState, interface: env?.interface))
        }
    }

    /// Marks the start of a phase; returns the monitor time (scaled) for later slicing.
    @discardableResult
    public func enter(_ phaseID: String, phase: StressPhaseKind, load: LoadType) -> Double {
        let t = now
        context.withLock { $0 = Context(phaseID: phaseID, phase: phase.rawValue, loadType: load, phaseStart: t) }
        return t
    }

    public func setLoad(_ direction: TransferDirection, mbps: Double?) {
        context.withLock { if direction == .download { $0.download = mbps } else { $0.upload = mbps } }
    }

    /// Samples sent in [from, to) (monitor time), rebased so the first window instant is 0, in
    /// unscaled seconds.
    public func latencySamples(from: Double, to: Double) -> [LatencySample] {
        let f = from / scale, t = to / scale
        return store.current.filter { $0.globalOffset >= f && $0.globalOffset < t }.enumerated().map {
            LatencySample(sequence: $0.offset, offset: $0.element.globalOffset - f, rttMs: $0.element.rttMs)
        }
    }

    public func samples(from: Double, to: Double) -> [MonitorSample] {
        let f = from / scale, t = to / scale
        return store.current.filter { $0.globalOffset >= f && $0.globalOffset < t }
    }

    /// Waits (at most ~0.5 s of real time) until `count` samples were sent since `since` — only
    /// matters in time-scaled tests; in the app the idle window is far longer than that.
    public func waitForSamples(since: Double, count: Int) async {
        let f = since / scale
        for _ in 0..<500 {
            if store.current.filter({ $0.globalOffset >= f }).count >= count || probe == nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Synchronous cancel (e.g. from `defer` when the test is cancelled).
    public func cancel() { task?.cancel() }

    public func stop() async -> ContinuousMonitorRecord? {
        task?.cancel()
        task = nil
        await probe?.close()
        guard let descriptor else { return nil }
        return ContinuousMonitorRecord(probe: descriptor, intervalSeconds: intervalSeconds, samples: store.current)
    }
}

// MARK: - Load primitive

/// Everything a stress engine needs: the throughput engines, the continuous monitor, byte
/// accounting with the data caps, and the live event sink. Shared by the Extreme Stress Test and
/// the toolbox so both measure with identical code.
public struct StressLoadContext: Sendable {
    public var speed: any SpeedTestEngineProtocol
    public var ndt7: any SpeedTestEngineProtocol
    public var monitor: ContinuousLatencyMonitor
    public var environment: EnvironmentRecorder?
    public var bytes: LockedValue<(down: Int64, up: Int64)>
    public var limits: StressDataLimits
    public var scale: Double
    public var emit: @Sendable (TestRunEvent) -> Void
    public var progress: LockedValue<StressProgress?>?
    /// Set once a load was skipped / cut because a data cap was reached.
    public var capReached = LockedValue(false)

    public init(speed: any SpeedTestEngineProtocol, ndt7: any SpeedTestEngineProtocol, monitor: ContinuousLatencyMonitor,
                environment: EnvironmentRecorder?, bytes: LockedValue<(down: Int64, up: Int64)>, limits: StressDataLimits, scale: Double,
                emit: @escaping @Sendable (TestRunEvent) -> Void, progress: LockedValue<StressProgress?>? = nil) {
        self.speed = speed
        self.ndt7 = ndt7
        self.monitor = monitor
        self.environment = environment
        self.bytes = bytes
        self.limits = limits
        self.scale = scale
        self.emit = emit
        self.progress = progress
    }

    public struct Run: Sendable {
        public var speed: SpeedResult?
        public var error: String?
        public var skippedForCap: Bool
    }

    public func remaining(_ direction: TransferDirection) -> Int64? {
        let b = bytes.current
        return limits.remaining(direction, down: b.down, up: b.up)
    }

    /// One load of `seconds` (real time; scaled internally). Never starts past a data cap and
    /// caps the running load at the remaining allowance. Endpoint failures are returned, not thrown.
    public func runLoad(server: ServerDescriptor, direction: TransferDirection, streams: Int?, seconds: Double,
                        ndt7 useNDT7: Bool = false) async throws -> Run {
        let remaining = remaining(direction)
        if let remaining, remaining <= 0 {
            capReached.withLock { $0 = true }
            return Run(speed: nil, error: "dataCapReached", skippedForCap: true)
        }
        let config = SpeedTestConfiguration(server: server, direction: direction, maxDuration: max(1, seconds * scale), autoDuration: nil,
                                            fixedStreams: useNDT7 ? nil : streams, byteCap: remaining)
        let engine = useNDT7 ? ndt7 : speed
        var result: SpeedResult?
        var last: Int64 = 0
        var lastUsageEmit = Date.distantPast
        do {
            for try await event in engine.run(config) {
                switch event {
                case .sample(let s):
                    emit(.speedSample(direction, s))
                    let delta = s.cumulativeBytes - last
                    last = s.cumulativeBytes
                    bytes.withLock { if direction == .download { $0.down += delta } else { $0.up += delta } }
                    monitor.setLoad(direction, mbps: s.mbps)
                    if let progress, Date().timeIntervalSince(lastUsageEmit) >= 1 {
                        lastUsageEmit = Date()
                        let b = bytes.current
                        let updated: StressProgress? = progress.withLock { (p: inout StressProgress?) -> StressProgress? in
                            p?.downloadBytes = b.down
                            p?.uploadBytes = b.up
                            return p
                        }
                        if let updated { emit(.stressProgress(updated)) }
                    }
                case .streamsChanged(let n): emit(.streams(direction, n))
                case .completed(let r): result = r
                }
            }
        } catch is CancellationError {
            monitor.setLoad(direction, mbps: nil)
            throw CancellationError()
        } catch {
            monitor.setLoad(direction, mbps: nil)
            return Run(speed: result, error: error.localizedDescription, skippedForCap: false)
        }
        monitor.setLoad(direction, mbps: nil)
        if let cap = remaining, last >= cap { capReached.withLock { $0 = true } }
        return Run(speed: result, error: result == nil ? "未完成" : nil, skippedForCap: false)
    }

    /// Waits `seconds` of real time (scaled in tests).
    public func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(max(0.0005, seconds * scale)))
    }
}

// MARK: - Engines (one implementation, used by the Extreme Stress Test and the toolbox)

/// Adaptive stream ramp: 1 → 2 → 4 → 8 → 16 → 24 → 32 streams until throughput stops growing.
public struct StreamRampEngine: Sendable {
    public init() {}

    public func run(_ ctx: StressLoadContext, node: StressNode, server: ServerDescriptor, stages: [Int] = StreamRampResult.defaultStages,
                    stageSeconds: Double, maxStreams: Int = 32, idleBaselineMs: Double?) async throws -> StreamRampResult? {
        var measured: [StreamRampStage] = []
        for n in stages where n <= maxStreams {
            try Task.checkCancellation()
            ctx.emit(.phase(.download))
            ctx.emit(.note(.download, "連線數階梯：\(n) 條連線"))
            let t0 = ctx.monitor.enter("ramp.s\(n)", phase: .streamRamp, load: .download)
            let run = try await ctx.runLoad(server: server, direction: .download, streams: n, seconds: stageSeconds)
            if run.skippedForCap { break }
            let warm = min(1, stageSeconds * 0.3)
            guard let speed = run.speed, let stats = LoadStats.make(speed, warmup: warm) else { continue }
            let latency = LatencyUnderLoad.make(ctx.monitor.latencySamples(from: t0 + warm * ctx.scale, to: ctx.monitor.now), idleMedianMs: idleBaselineMs)
            measured.append(StreamRampStage(streamCount: n, throughput: stats, latency: latency, gainPercent: nil, samples: speed.samples))
            let analyzed = StreamRampResult.analyze(direction: .download, method: "HTTP", targetNodeID: node.id, stages: measured)
            if StreamRampResult.shouldStop(analyzed.stages.map(\.gainPercent)) { break }
        }
        guard !measured.isEmpty else { return nil }
        return StreamRampResult.analyze(direction: .download, method: "HTTP (fixed streams per stage)", targetNodeID: node.id, stages: measured)
    }
}

/// Sustained single-direction saturation at a fixed stream count.
public struct SustainedLoadEngine: Sendable {
    public init() {}

    public func run(_ ctx: StressLoadContext, node: StressNode, server: ServerDescriptor, direction: TransferDirection, streams: Int,
                    seconds: Double, idleBaselineMs: Double?) async throws -> SustainedLoadResult {
        ctx.emit(.phase(direction == .download ? .download : .upload))
        let kind: StressPhaseKind = direction == .download ? .sustainedDownload : .sustainedUpload
        let thermalStart = EnvironmentRecorder.thermalState()
        let t0 = ctx.monitor.enter(kind.rawValue, phase: kind, load: direction == .download ? .download : .upload)
        let run = try await ctx.runLoad(server: server, direction: direction, streams: streams, seconds: seconds)
        let end = ctx.monitor.now
        let latency = LatencyUnderLoad.make(ctx.monitor.latencySamples(from: t0 + 1 * ctx.scale, to: end), idleMedianMs: idleBaselineMs)
        let pathChanges = ctx.monitor.samples(from: t0, to: end).map(\.interface)
        let changes = zip(pathChanges, pathChanges.dropFirst()).filter { $0 != $1 }.count
        return SustainedLoadResult(direction: direction, method: "HTTP x\(streams)", targetNodeID: node.id, streams: streams, plannedSeconds: seconds,
                                   throughput: LoadStats.make(run.speed), latency: latency, pathChanges: changes,
                                   thermalStateStart: thermalStart, thermalStateEnd: EnvironmentRecorder.thermalState(),
                                   samples: run.speed?.samples ?? [], error: run.skippedForCap ? "dataCapReached" : run.error)
    }
}

/// Download and upload at the same time on one node, with the control probe running.
public struct FullDuplexStressEngine: Sendable {
    public init() {}

    public func run(_ ctx: StressLoadContext, node: StressNode, server: ServerDescriptor, downloadStreams: Int, uploadStreams: Int,
                    seconds: Double, idleBaselineMs: Double?, downloadOnlyMbps: Double?, uploadOnlyMbps: Double?) async throws -> FullDuplexResult {
        ctx.emit(.phase(.download))
        ctx.emit(.note(.download, "全雙工：下載與上傳同時滿載"))
        let t0 = ctx.monitor.enter(StressPhaseKind.fullDuplex.rawValue, phase: .fullDuplex, load: .fullDuplex)
        async let down = ctx.runLoad(server: server, direction: .download, streams: downloadStreams, seconds: seconds)
        async let up = ctx.runLoad(server: server, direction: .upload, streams: uploadStreams, seconds: seconds)
        let (d, u) = try await (down, up)
        let latency = LatencyUnderLoad.make(ctx.monitor.latencySamples(from: t0 + 1 * ctx.scale, to: ctx.monitor.now), idleMedianMs: idleBaselineMs)
        return FullDuplexResult(targetNodeID: node.id, downloadStreams: downloadStreams, uploadStreams: uploadStreams, plannedSeconds: seconds,
                                download: LoadStats.make(d.speed), upload: LoadStats.make(u.speed),
                                downloadOnlyReferenceMbps: downloadOnlyMbps, uploadOnlyReferenceMbps: uploadOnlyMbps, latency: latency,
                                downloadSamples: d.speed?.samples ?? [], uploadSamples: u.speed?.samples ?? [])
    }
}

/// Repeated idle → saturation → idle cycles (3 s load, 2 s idle by default).
public struct BurstStressEngine: Sendable {
    public init() {}

    public func run(_ ctx: StressLoadContext, node: StressNode, server: ServerDescriptor, streams: Int, cycles: Int,
                    loadSeconds: Double = 3, idleSeconds: Double = 2, idleBaselineMs: Double?) async throws -> BurstResult {
        var out: [BurstCycle] = []
        let s = ctx.scale
        for i in 1...max(1, cycles) {
            try Task.checkCancellation()
            ctx.emit(.phase(.download))
            let loadStart = ctx.monitor.enter("burst.c\(i).load", phase: .burst, load: .burstLoad)
            let run = try await ctx.runLoad(server: server, direction: .download, streams: streams, seconds: loadSeconds)
            if run.skippedForCap { break }
            let loadEnd = ctx.monitor.enter("burst.c\(i).idle", phase: .burst, load: .burstIdle)
            try await ctx.pause(idleSeconds)
            let idleEnd = ctx.monitor.now

            let before = ctx.monitor.samples(from: loadStart - idleSeconds * s, to: loadStart).compactMap(\.rttMs)
            let during = ctx.monitor.samples(from: loadStart, to: loadEnd)
            let after = ctx.monitor.samples(from: loadEnd, to: idleEnd)
            let base = idleBaselineMs ?? Descriptive.median(before)
            let rates = run.speed?.samples.map(\.mbps) ?? []
            let median = Descriptive.median(rates)
            let ramp = median.flatMap { m in run.speed?.samples.first { $0.mbps >= 0.8 * m }.map { $0.offset * 1000 } }
            var queueBuild: Double?, recovery: Double?
            if let base {
                let high = base + max(20, 0.5 * base)
                queueBuild = during.first { ($0.rttMs ?? 0) > high }.map { ($0.globalOffset - loadStart / s) * 1000 }
                let limit = base + max(5, 0.1 * base)
                let answered = after.filter { $0.rttMs != nil }
                for (a, b) in zip(answered, answered.dropFirst()) where a.rttMs! <= limit && b.rttMs! <= limit {
                    recovery = (a.globalOffset - loadEnd / s) * 1000
                    break
                }
            }
            let lost = (during + after).filter { $0.rttMs == nil }.count
            let total = (during + after).count
            out.append(BurstCycle(index: i, loadSeconds: loadSeconds, idleSeconds: idleSeconds,
                                  burstStartLatencyMs: Descriptive.median(before), peakLoadedLatencyMs: during.compactMap(\.rttMs).max(),
                                  throughputMbps: run.speed?.bestAverageMbps, throughputRampTimeMs: ramp, queueBuildTimeMs: queueBuild,
                                  recoveryTimeMs: recovery, postBurstLatencyMs: Descriptive.median(after.compactMap(\.rttMs)),
                                  lossPercent: total > 0 ? Double(lost) / Double(total) * 100 : nil,
                                  bytes: run.speed?.samples.last?.cumulativeBytes ?? 0, samples: run.speed?.samples ?? []))
        }
        return BurstResult(targetNodeID: node.id, method: "HTTP x\(streams)", streams: streams, cycles: out, idleBaselineMs: idleBaselineMs)
    }
}

/// Several destinations downloading at once (saturation load, not a provider comparison).
public struct MultiDestinationStressEngine: Sendable {
    public init() {}

    public func run(_ ctx: StressLoadContext, targets: [StressNode], streams: Int, seconds: Double, idleBaselineMs: Double?,
                    bestSingleStandardMbps: Double?) async throws -> MultiDestinationResult {
        ctx.emit(.phase(.download))
        ctx.emit(.note(.download, "多目的地同時下載：\(targets.map(\.name).joined(separator: " + "))"))
        let t0 = ctx.monitor.enter(StressPhaseKind.multiDestination.rawValue, phase: .multiDestination, load: .multiDestination)
        let loads = try await withThrowingTaskGroup(of: DestinationLoad?.self) { group in
            for node in targets {
                guard let server = node.server else { continue }
                group.addTask {
                    let ndt7 = node.provider == .mlab
                    let run = try await ctx.runLoad(server: server, direction: .download, streams: ndt7 ? nil : streams, seconds: seconds, ndt7: ndt7)
                    return DestinationLoad(nodeID: node.id, name: node.name, provider: node.provider,
                                           method: ndt7 ? "NDT7 WebSocket" : "HTTP", streamCount: ndt7 ? 1 : streams,
                                           throughput: LoadStats.make(run.speed), samples: run.speed?.samples ?? [])
                }
            }
            var out: [DestinationLoad] = []
            for try await d in group { if let d { out.append(d) } }
            return out.sorted { $0.nodeID < $1.nodeID }
        }
        let latency = LatencyUnderLoad.make(ctx.monitor.latencySamples(from: t0 + 1 * ctx.scale, to: ctx.monitor.now), idleMedianMs: idleBaselineMs)
        return MultiDestinationResult(plannedSeconds: seconds, destinations: loads, latency: latency, bestSingleStandardMbps: bestSingleStandardMbps)
    }
}

/// Watches the control latency after a load until it is back at the idle baseline.
public struct RecoveryEngine: Sendable {
    public init() {}

    public func run(_ ctx: StressLoadContext, kind: String, afterPhase: String, seconds: Double, idleBaselineMs: Double?) async throws -> RecoveryResult {
        let phase: StressPhaseKind = kind == "final" ? .finalRecovery : .shortRecovery
        let t0 = ctx.monitor.enter("recovery.\(afterPhase)", phase: phase, load: .recovery)
        try await ctx.pause(seconds)
        return RecoveryResult.analyze(kind: kind, afterPhase: afterPhase, plannedSeconds: seconds,
                                      samples: ctx.monitor.latencySamples(from: t0, to: ctx.monitor.now), baselineMedianMs: idleBaselineMs)
    }
}
