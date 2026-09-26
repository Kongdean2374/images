import Foundation

// MARK: - Continuous monitor

/// What the link was doing when a monitor sample was taken.
public enum LoadType: String, Codable, Sendable, Hashable {
    case idle, download, upload, fullDuplex, burstLoad, burstIdle, multiDestination, recovery, diagnostics, packetLoss, standard
}

/// One sample of the continuous control-latency monitor that runs through the whole stress test.
public struct MonitorSample: Codable, Sendable, Hashable {
    /// Seconds since the monitor started (send time of the probe).
    public var globalOffset: Double
    /// Unique id of the phase instance (e.g. "ramp.s8", "burst.c3.load", "recovery.final").
    public var phaseID: String
    /// Phase kind (`StressPhaseKind.rawValue`).
    public var phase: String
    /// Seconds since that phase started.
    public var phaseOffset: Double
    public var rttMs: Double?
    public var loadType: LoadType
    /// Live load at the time of the sample (Mbps of the running transfer(s); nil = no load).
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    /// `ProcessInfo.thermalState` ("nominal", "fair", "serious", "critical") or nil when not sampled.
    public var thermalState: String?
    /// Primary interface at the time ("wifi", "cellular", …) or nil.
    public var interface: String?

    public init(globalOffset: Double, phaseID: String, phase: String, phaseOffset: Double, rttMs: Double?, loadType: LoadType,
                downloadMbps: Double? = nil, uploadMbps: Double? = nil, thermalState: String? = nil, interface: String? = nil) {
        self.globalOffset = globalOffset
        self.phaseID = phaseID
        self.phase = phase
        self.phaseOffset = phaseOffset
        self.rttMs = rttMs
        self.loadType = loadType
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.thermalState = thermalState
        self.interface = interface
    }
}

/// All samples of the continuous monitor (one fixed target + method for the whole test), so any
/// latency spike can be placed in the phase it happened in.
public struct ContinuousMonitorRecord: Codable, Sendable, Hashable {
    public var probe: ProbeDescriptor
    public var intervalSeconds: Double
    public var samples: [MonitorSample]

    public init(probe: ProbeDescriptor, intervalSeconds: Double, samples: [MonitorSample]) {
        self.probe = probe
        self.intervalSeconds = intervalSeconds
        self.samples = samples
    }

    /// Samples of phase ids with the given prefix, as `LatencySample`s rebased to the first one.
    public func latencySamples(phasePrefix: String) -> [LatencySample] {
        Self.rebase(samples.filter { $0.phaseID.hasPrefix(phasePrefix) })
    }

    public func latencySamples(from start: Double, to end: Double) -> [LatencySample] {
        Self.rebase(samples.filter { $0.globalOffset >= start && $0.globalOffset < end })
    }

    static func rebase(_ s: [MonitorSample]) -> [LatencySample] {
        guard let first = s.first?.globalOffset else { return [] }
        return s.enumerated().map { LatencySample(sequence: $0.offset, offset: $0.element.globalOffset - first, rttMs: $0.element.rttMs) }
    }
}

// MARK: - Shared statistics

/// Throughput statistics of one stress phase (all from the raw 100 ms samples).
///
///     initial  = mean rate of the first `edge` s after warm-up        final = mean rate of the last `edge` s
///     degradation % = (initial − final) / initial × 100              (positive = slower at the end)
public struct LoadStats: Codable, Sendable, Hashable {
    public var averageMbps: Double
    public var medianMbps: Double
    public var p10Mbps: Double
    public var p95Mbps: Double
    public var peakMbps: Double
    public var initialMbps: Double?
    public var finalMbps: Double?
    public var degradationPercent: Double?
    public var bytes: Int64
    public var durationSeconds: Double
    /// Short-window statistics are unreliable (progress reported in bursts, e.g. upload).
    public var samplingArtifact: Bool

    public static let edgeSeconds = 3.0

    public static func make(_ speed: SpeedResult?, warmup: Double = 1.0) -> LoadStats? {
        guard let speed, !speed.samples.isEmpty else { return nil }
        let m = speed.summary
        let steady = speed.samples.filter { $0.offset > warmup }
        func rate(_ s: [SpeedSample]) -> Double? {
            let d = s.reduce(0) { $0 + $1.intervalDuration }
            return d > 0 ? SpeedMath.mbps(bytes: s.reduce(0) { $0 + $1.intervalBytes }, seconds: d) : nil
        }
        let span = (steady.last?.offset ?? 0) - (steady.first?.offset ?? 0)
        let edge = min(edgeSeconds, max(0.5, span / 3))
        let first = steady.first?.offset ?? 0, last = steady.last?.offset ?? 0
        let initial = rate(steady.filter { $0.offset <= first + edge })
        let final = rate(steady.filter { $0.offset > last - edge })
        let degradation = initial.flatMap { i in final.map { i > 0 ? (i - $0) / i * 100 : 0 } }
        return LoadStats(averageMbps: speed.bestAverageMbps, medianMbps: m.medianMbps, p10Mbps: m.p10Mbps, p95Mbps: m.p95Mbps,
                         peakMbps: m.peakMbps, initialMbps: initial, finalMbps: final,
                         degradationPercent: span >= 2 * edge ? degradation : nil,
                         bytes: speed.samples.last?.cumulativeBytes ?? 0, durationSeconds: speed.samples.last?.offset ?? 0,
                         samplingArtifact: !m.shortWindowReliable)
    }

    public init(averageMbps: Double, medianMbps: Double, p10Mbps: Double, p95Mbps: Double, peakMbps: Double, initialMbps: Double? = nil, finalMbps: Double? = nil, degradationPercent: Double? = nil, bytes: Int64, durationSeconds: Double, samplingArtifact: Bool) {
        self.averageMbps = averageMbps
        self.medianMbps = medianMbps
        self.p10Mbps = p10Mbps
        self.p95Mbps = p95Mbps
        self.peakMbps = peakMbps
        self.initialMbps = initialMbps
        self.finalMbps = finalMbps
        self.degradationPercent = degradationPercent
        self.bytes = bytes
        self.durationSeconds = durationSeconds
        self.samplingArtifact = samplingArtifact
    }
}

/// Control latency during a load phase compared with the idle control baseline (same probe).
public struct LatencyUnderLoad: Codable, Sendable, Hashable {
    public var medianMs: Double?
    public var p95Ms: Double?
    public var p99Ms: Double?
    public var jitterMs: Double?
    public var lossPercent: Double?
    public var sampleCount: Int
    public var idleMedianMs: Double?
    /// median(load) − median(idle), same target + method (never negative-clipped).
    public var inflationMs: Double?

    public static func make(_ samples: [LatencySample], idleMedianMs: Double?) -> LatencyUnderLoad? {
        guard !samples.isEmpty else { return nil }
        let s = LatencyStatistics.compute(from: samples)
        let median = s.rtt?.median
        return LatencyUnderLoad(medianMs: median, p95Ms: s.rtt?.p95, p99Ms: s.rtt?.p99, jitterMs: s.rtt?.jitter,
                                lossPercent: s.sent > 0 ? s.loss.lossPercent : nil, sampleCount: s.sent, idleMedianMs: idleMedianMs,
                                inflationMs: median.flatMap { m in idleMedianMs.map { m - $0 } })
    }

    public init(medianMs: Double? = nil, p95Ms: Double? = nil, p99Ms: Double? = nil, jitterMs: Double? = nil, lossPercent: Double? = nil, sampleCount: Int, idleMedianMs: Double? = nil, inflationMs: Double? = nil) {
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.p99Ms = p99Ms
        self.jitterMs = jitterMs
        self.lossPercent = lossPercent
        self.sampleCount = sampleCount
        self.idleMedianMs = idleMedianMs
        self.inflationMs = inflationMs
    }
}

// MARK: - Adaptive stream ramp

public struct StreamRampStage: Codable, Sendable, Hashable {
    public var streamCount: Int
    public var throughput: LoadStats
    public var latency: LatencyUnderLoad?
    /// Gain of this stage's average over the previous stage's (%); nil for the first stage.
    public var gainPercent: Double?
    public var samples: [SpeedSample]

    public init(streamCount: Int, throughput: LoadStats, latency: LatencyUnderLoad? = nil, gainPercent: Double? = nil, samples: [SpeedSample]) {
        self.streamCount = streamCount
        self.throughput = throughput
        self.latency = latency
        self.gainPercent = gainPercent
        self.samples = samples
    }
}

/// Saturation search: streams 1, 2, 4, 8, 16, 24, 32 until throughput stops growing.
///
///     gainᵢ                = (avgᵢ − avgᵢ₋₁) / avgᵢ₋₁ × 100
///     saturation stage     = the stage before the first of two consecutive stages with gain < 3 %,
///                            or before the first stage whose throughput declines
///     optimal streams      = fewest streams whose average ≥ 97 % of the best average
///     scaling efficiency   = 100 × (avg(sat) − avg(1st)) / (max avg − avg(1st))   (share of the achievable gain)
///     connection efficiency = avg(sat) / streams(sat)  (Mbps per stream)
public struct StreamRampResult: Codable, Sendable, Hashable {
    public var direction: TransferDirection
    public var method: String
    public var targetNodeID: String
    public var stages: [StreamRampStage]
    public var saturationDetected: Bool
    public var saturationStreamCount: Int?
    public var saturationThroughputMbps: Double?
    public var optimalStreamCount: Int?
    public var maxObservedStreamCount: Int
    public var marginalGainPercent: Double?
    public var scalingEfficiency0_100: Double?
    public var connectionEfficiencyMbpsPerStream: Double?

    public static let plateauGainPercent = 3.0
    public static let defaultStages = [1, 2, 4, 8, 16, 24, 32]

    /// True when the next stage need not be measured (two flat / declining stages already seen).
    ///     stop ⇔ the last two gains are both < 3 %, or the last gain < −3 % (throughput fell)
    public static func shouldStop(_ gains: [Double?]) -> Bool {
        let g = gains.compactMap { $0 }
        if let last = g.last, last < -plateauGainPercent { return true }
        return g.count >= 2 && g.suffix(2).allSatisfy { $0 < plateauGainPercent }
    }

    public static func analyze(direction: TransferDirection, method: String, targetNodeID: String,
                               stages raw: [StreamRampStage]) -> StreamRampResult {
        var stages = raw
        for i in stages.indices where i > 0 {
            let prev = stages[i - 1].throughput.averageMbps
            stages[i].gainPercent = prev > 0 ? (stages[i].throughput.averageMbps - prev) / prev * 100 : nil
        }
        var saturationIndex: Int?
        for i in stages.indices where i > 0 {
            guard let g = stages[i].gainPercent else { continue }
            let next = i + 1 < stages.count ? stages[i + 1].gainPercent : nil
            if g < 0 || (g < plateauGainPercent && (next == nil || next! < plateauGainPercent)) {
                saturationIndex = i - 1
                break
            }
        }
        let averages = stages.map(\.throughput.averageMbps)
        let best = averages.max() ?? 0
        let optimal = stages.first { $0.throughput.averageMbps >= 0.97 * best }?.streamCount
        let sat = saturationIndex.map { stages[$0] }
        var efficiency: Double?
        if let sat, let first = averages.first, best > first { efficiency = min(100, max(0, (sat.throughput.averageMbps - first) / (best - first) * 100)) }
        else if sat != nil { efficiency = 100 }
        return StreamRampResult(direction: direction, method: method, targetNodeID: targetNodeID, stages: stages,
                                saturationDetected: sat != nil, saturationStreamCount: sat?.streamCount,
                                saturationThroughputMbps: sat?.throughput.averageMbps, optimalStreamCount: optimal,
                                maxObservedStreamCount: stages.map(\.streamCount).max() ?? 0,
                                marginalGainPercent: stages.last?.gainPercent, scalingEfficiency0_100: efficiency,
                                connectionEfficiencyMbpsPerStream: sat.map { $0.throughput.averageMbps / Double(max($0.streamCount, 1)) })
    }

    /// Streams the later stress phases use: saturation point, else the optimal count, else 16.
    public var recommendedStreams: Int { saturationStreamCount ?? optimalStreamCount ?? 16 }

    public init(direction: TransferDirection, method: String, targetNodeID: String, stages: [StreamRampStage], saturationDetected: Bool, saturationStreamCount: Int? = nil, saturationThroughputMbps: Double? = nil, optimalStreamCount: Int? = nil, maxObservedStreamCount: Int, marginalGainPercent: Double? = nil, scalingEfficiency0_100: Double? = nil, connectionEfficiencyMbpsPerStream: Double? = nil) {
        self.direction = direction
        self.method = method
        self.targetNodeID = targetNodeID
        self.stages = stages
        self.saturationDetected = saturationDetected
        self.saturationStreamCount = saturationStreamCount
        self.saturationThroughputMbps = saturationThroughputMbps
        self.optimalStreamCount = optimalStreamCount
        self.maxObservedStreamCount = maxObservedStreamCount
        self.marginalGainPercent = marginalGainPercent
        self.scalingEfficiency0_100 = scalingEfficiency0_100
        self.connectionEfficiencyMbpsPerStream = connectionEfficiencyMbpsPerStream
    }
}

// MARK: - Sustained / full duplex / burst / multi-destination

public struct SustainedLoadResult: Codable, Sendable, Hashable {
    public var direction: TransferDirection
    public var method: String
    public var targetNodeID: String
    public var streams: Int
    public var plannedSeconds: Double
    public var throughput: LoadStats?
    public var latency: LatencyUnderLoad?
    public var pathChanges: Int
    public var thermalStateStart: String?
    public var thermalStateEnd: String?
    public var samples: [SpeedSample]
    public var error: String?

    public init(direction: TransferDirection, method: String, targetNodeID: String, streams: Int, plannedSeconds: Double, throughput: LoadStats? = nil, latency: LatencyUnderLoad? = nil, pathChanges: Int, thermalStateStart: String? = nil, thermalStateEnd: String? = nil, samples: [SpeedSample], error: String? = nil) {
        self.direction = direction
        self.method = method
        self.targetNodeID = targetNodeID
        self.streams = streams
        self.plannedSeconds = plannedSeconds
        self.throughput = throughput
        self.latency = latency
        self.pathChanges = pathChanges
        self.thermalStateStart = thermalStateStart
        self.thermalStateEnd = thermalStateEnd
        self.samples = samples
        self.error = error
    }
}

public struct FullDuplexResult: Codable, Sendable, Hashable {
    public var targetNodeID: String
    public var downloadStreams: Int
    public var uploadStreams: Int
    public var plannedSeconds: Double
    public var download: LoadStats?
    public var upload: LoadStats?
    /// Single-direction references measured with the same node / method in this run.
    public var downloadOnlyReferenceMbps: Double?
    public var uploadOnlyReferenceMbps: Double?
    public var latency: LatencyUnderLoad?
    public var downloadSamples: [SpeedSample]
    public var uploadSamples: [SpeedSample]
    /// Never inferred from the phone: modem / radio scheduler / access / core are indistinguishable here.
    public var queueLocation: String = "unknown"

    public var downloadDegradationPercent: Double? {
        guard let ref = downloadOnlyReferenceMbps, ref > 0, let d = download?.averageMbps else { return nil }
        return (ref - d) / ref * 100
    }
    public var uploadDegradationPercent: Double? {
        guard let ref = uploadOnlyReferenceMbps, ref > 0, let u = upload?.averageMbps else { return nil }
        return (ref - u) / ref * 100
    }

    public init(targetNodeID: String, downloadStreams: Int, uploadStreams: Int, plannedSeconds: Double, download: LoadStats? = nil, upload: LoadStats? = nil, downloadOnlyReferenceMbps: Double? = nil, uploadOnlyReferenceMbps: Double? = nil, latency: LatencyUnderLoad? = nil, downloadSamples: [SpeedSample], uploadSamples: [SpeedSample], queueLocation: String = "unknown") {
        self.targetNodeID = targetNodeID
        self.downloadStreams = downloadStreams
        self.uploadStreams = uploadStreams
        self.plannedSeconds = plannedSeconds
        self.download = download
        self.upload = upload
        self.downloadOnlyReferenceMbps = downloadOnlyReferenceMbps
        self.uploadOnlyReferenceMbps = uploadOnlyReferenceMbps
        self.latency = latency
        self.downloadSamples = downloadSamples
        self.uploadSamples = uploadSamples
        self.queueLocation = queueLocation
    }
}

/// One idle → load → idle cycle.
public struct BurstCycle: Codable, Sendable, Hashable {
    public var index: Int
    public var loadSeconds: Double
    public var idleSeconds: Double
    /// Control latency just before the load started (median of the preceding idle samples).
    public var burstStartLatencyMs: Double?
    public var peakLoadedLatencyMs: Double?
    public var throughputMbps: Double?
    /// Load start → first 100 ms sample ≥ 80 % of the cycle's median rate.
    public var throughputRampTimeMs: Double?
    /// Load start → first control sample above baseline + max(20 ms, 50 %).
    public var queueBuildTimeMs: Double?
    /// Load end → first control sample back within baseline + max(5 ms, 10 %); nil = not within the idle window.
    public var recoveryTimeMs: Double?
    public var postBurstLatencyMs: Double?
    public var lossPercent: Double?
    public var bytes: Int64
    public var samples: [SpeedSample]

    public init(index: Int, loadSeconds: Double, idleSeconds: Double, burstStartLatencyMs: Double? = nil, peakLoadedLatencyMs: Double? = nil, throughputMbps: Double? = nil, throughputRampTimeMs: Double? = nil, queueBuildTimeMs: Double? = nil, recoveryTimeMs: Double? = nil, postBurstLatencyMs: Double? = nil, lossPercent: Double? = nil, bytes: Int64, samples: [SpeedSample]) {
        self.index = index
        self.loadSeconds = loadSeconds
        self.idleSeconds = idleSeconds
        self.burstStartLatencyMs = burstStartLatencyMs
        self.peakLoadedLatencyMs = peakLoadedLatencyMs
        self.throughputMbps = throughputMbps
        self.throughputRampTimeMs = throughputRampTimeMs
        self.queueBuildTimeMs = queueBuildTimeMs
        self.recoveryTimeMs = recoveryTimeMs
        self.postBurstLatencyMs = postBurstLatencyMs
        self.lossPercent = lossPercent
        self.bytes = bytes
        self.samples = samples
    }
}

public struct BurstResult: Codable, Sendable, Hashable {
    public var targetNodeID: String
    public var method: String
    public var streams: Int
    public var cycles: [BurstCycle]
    public var idleBaselineMs: Double?

    public var recoveryTimes: [Double] { cycles.compactMap(\.recoveryTimeMs) }
    public var medianRecoveryTimeMs: Double? { Descriptive.median(recoveryTimes) }
    public var p95RecoveryTimeMs: Double? { Percentile.value(0.95, in: recoveryTimes) }
    public var worstRecoveryTimeMs: Double? { recoveryTimes.max() }
    /// Cycles whose latency did not come back within the idle window.
    public var unrecoveredCycles: Int { cycles.filter { $0.recoveryTimeMs == nil && $0.peakLoadedLatencyMs != nil }.count }
    public var latencyInflationMs: Double? {
        guard let base = idleBaselineMs, let peak = Descriptive.median(cycles.compactMap(\.peakLoadedLatencyMs)) else { return nil }
        return peak - base
    }
    public var lossPercent: Double? { Descriptive.mean(cycles.compactMap(\.lossPercent)) }

    /// 0–100: 100 − recovery (median ms / 20, max 50) − unrecovered share × 30 − loss × 10.
    public var stabilityScore: Double? {
        guard !cycles.isEmpty else { return nil }
        let rec = min(50, (medianRecoveryTimeMs ?? 2_000) / 20)
        let unrec = Double(unrecoveredCycles) / Double(cycles.count) * 30
        return max(0, min(100, 100 - rec - unrec - (lossPercent ?? 0) * 10))
    }

    public init(targetNodeID: String, method: String, streams: Int, cycles: [BurstCycle], idleBaselineMs: Double? = nil) {
        self.targetNodeID = targetNodeID
        self.method = method
        self.streams = streams
        self.cycles = cycles
        self.idleBaselineMs = idleBaselineMs
    }
}

public struct DestinationLoad: Codable, Sendable, Hashable {
    public var nodeID: String
    public var name: String
    public var provider: StressProvider
    public var method: String
    public var streamCount: Int
    public var throughput: LoadStats?
    public var samples: [SpeedSample]

    public init(nodeID: String, name: String, provider: StressProvider, method: String, streamCount: Int, throughput: LoadStats? = nil, samples: [SpeedSample]) {
        self.nodeID = nodeID
        self.name = name
        self.provider = provider
        self.method = method
        self.streamCount = streamCount
        self.throughput = throughput
        self.samples = samples
    }
}

/// Several destinations downloading at the same time. A saturation-load indicator, never a
/// provider benchmark (methods differ).
public struct MultiDestinationResult: Codable, Sendable, Hashable {
    public var plannedSeconds: Double
    public var destinations: [DestinationLoad]
    public var latency: LatencyUnderLoad?
    /// Best single-destination *standard* download of this run (same session).
    public var bestSingleStandardMbps: Double?

    public var aggregateMbps: Double { destinations.compactMap { $0.throughput?.averageMbps }.reduce(0, +) }
    public var methodEquivalent: Bool { Set(destinations.map { "\($0.method)|\($0.streamCount)" }).count <= 1 }
    /// Aggregate ≥ 1.2 × the best single destination: a single-destination limitation is *possible*
    /// (server, CDN, route, protocol or stream count — not distinguishable here).
    public var singleDestinationLimitationPossible: Bool {
        guard let best = bestSingleStandardMbps, best > 0, destinations.count >= 2 else { return false }
        return aggregateMbps >= 1.2 * best
    }

    public init(plannedSeconds: Double, destinations: [DestinationLoad], latency: LatencyUnderLoad? = nil, bestSingleStandardMbps: Double? = nil) {
        self.plannedSeconds = plannedSeconds
        self.destinations = destinations
        self.latency = latency
        self.bestSingleStandardMbps = bestSingleStandardMbps
    }
}

// MARK: - Recovery

/// Latency after a load stopped, against the idle control baseline (same probe).
///
///     within X %  ⇔ rtt ≤ baseline × (1 + X) or rtt ≤ baseline + 2 ms, held for 2 consecutive samples
///     time_to_within_X = send offset of the first such sample; nil (and recovery_complete=false)
///     when it never happens inside the window — no value is invented.
public struct RecoveryResult: Codable, Sendable, Hashable {
    /// "short" or "final".
    public var kind: String
    public var afterPhase: String
    public var plannedSeconds: Double
    public var baselineMedianMs: Double?
    public var samples: [LatencySample]
    public var recoveryTime10PercentMs: Double?
    public var recoveryTime20PercentMs: Double?
    public var complete: Bool
    public var lossPercent: Double?
    public var jitterMs: Double?
    public var medianMs: Double?
    public var spikeCount: Int

    public static func analyze(kind: String, afterPhase: String, plannedSeconds: Double, samples: [LatencySample],
                               baselineMedianMs: Double?) -> RecoveryResult {
        let ordered = samples.sorted { $0.sequence < $1.sequence }
        func within(_ fraction: Double) -> Double? {
            guard let base = baselineMedianMs else { return nil }
            let limit = max(base * (1 + fraction), base + 2)
            for i in ordered.indices where i + 1 < ordered.count {
                if let a = ordered[i].rttMs, let b = ordered[i + 1].rttMs, a <= limit, b <= limit { return ordered[i].offset * 1000 }
            }
            return nil
        }
        let stats = LatencyStatistics.compute(from: ordered)
        let spikes = baselineMedianMs.map { base in ordered.filter { ($0.rttMs ?? 0) > max(base * 2, base + 50) }.count } ?? 0
        let t10 = within(0.10)
        return RecoveryResult(kind: kind, afterPhase: afterPhase, plannedSeconds: plannedSeconds, baselineMedianMs: baselineMedianMs,
                              samples: ordered, recoveryTime10PercentMs: t10, recoveryTime20PercentMs: within(0.20),
                              complete: t10 != nil, lossPercent: stats.sent > 0 ? stats.loss.lossPercent : nil,
                              jitterMs: stats.rtt?.jitter, medianMs: stats.rtt?.median, spikeCount: spikes)
    }

    public init(kind: String, afterPhase: String, plannedSeconds: Double, baselineMedianMs: Double? = nil, samples: [LatencySample], recoveryTime10PercentMs: Double? = nil, recoveryTime20PercentMs: Double? = nil, complete: Bool, lossPercent: Double? = nil, jitterMs: Double? = nil, medianMs: Double? = nil, spikeCount: Int) {
        self.kind = kind
        self.afterPhase = afterPhase
        self.plannedSeconds = plannedSeconds
        self.baselineMedianMs = baselineMedianMs
        self.samples = samples
        self.recoveryTime10PercentMs = recoveryTime10PercentMs
        self.recoveryTime20PercentMs = recoveryTime20PercentMs
        self.complete = complete
        self.lossPercent = lossPercent
        self.jitterMs = jitterMs
        self.medianMs = medianMs
        self.spikeCount = spikeCount
    }
}

// MARK: - Environment

public struct EnvironmentSample: Codable, Sendable, Hashable {
    public var offset: Double
    /// "nominal" | "fair" | "serious" | "critical" (ProcessInfo.thermalState).
    public var thermalState: String
    /// 0–100, nil = unavailable (simulator / monitoring disabled).
    public var batteryPercent: Double?
    /// "charging" | "full" | "unplugged" | "unknown" | nil (unavailable).
    public var batteryState: String?
    public var lowPowerMode: Bool?
    public var interface: String?
    /// Radio access technology when on cellular (e.g. "NR", "LTE"), nil = unavailable.
    public var radioTechnology: String?

    public init(offset: Double, thermalState: String, batteryPercent: Double?, batteryState: String?, lowPowerMode: Bool?,
                interface: String?, radioTechnology: String?) {
        self.offset = offset
        self.thermalState = thermalState
        self.batteryPercent = batteryPercent
        self.batteryState = batteryState
        self.lowPowerMode = lowPowerMode
        self.interface = interface
        self.radioTechnology = radioTechnology
    }
}

/// Device / link environment during the stress test. Correlation only: a thermal-state change
/// never proves thermal throttling of the network.
public struct EnvironmentRecord: Codable, Sendable, Hashable {
    public var samples: [EnvironmentSample]

    public init(samples: [EnvironmentSample]) { self.samples = samples }

    static let thermalOrder = ["nominal": 0, "fair": 1, "serious": 2, "critical": 3]
    public var thermalStart: String? { samples.first?.thermalState }
    public var thermalEnd: String? { samples.last?.thermalState }
    public var thermalPeak: String? { samples.max { (Self.thermalOrder[$0.thermalState] ?? 0) < (Self.thermalOrder[$1.thermalState] ?? 0) }?.thermalState }
    public var thermalChangeOffsets: [Double] { changes(\.thermalState) }
    public var interfaceChangeOffsets: [Double] { changes(\.interface) }
    public var radioChangeOffsets: [Double] { changes(\.radioTechnology) }
    public var batteryStart: Double? { samples.first?.batteryPercent }
    public var batteryEnd: Double? { samples.last?.batteryPercent }
    public var thermalRose: Bool { (Self.thermalOrder[thermalPeak ?? "nominal"] ?? 0) > (Self.thermalOrder[thermalStart ?? "nominal"] ?? 0) }

    func changes<T: Equatable>(_ key: KeyPath<EnvironmentSample, T>) -> [Double] {
        zip(samples, samples.dropFirst()).compactMap { a, b in a[keyPath: key] != b[keyPath: key] ? b.offset : nil }
    }
}

// MARK: - Report

/// Everything the upgraded stress phases measured. Used by the Extreme Stress Test and by every
/// toolbox stress tool (same engines, same model).
public struct StressLoadReport: Codable, Sendable, Hashable {
    public var streamRamp: StreamRampResult?
    public var sustainedDownload: SustainedLoadResult?
    public var sustainedUpload: SustainedLoadResult?
    public var fullDuplex: FullDuplexResult?
    public var burst: BurstResult?
    public var multiDestination: MultiDestinationResult?
    public var recoveries: [RecoveryResult]
    public var monitor: ContinuousMonitorRecord?
    public var environment: EnvironmentRecord?
    /// Control-probe idle median (the baseline of every inflation / recovery value).
    public var idleControlMedianMs: Double?
    /// Standard (normal speed-test) references of this run, for cross-load impact.
    public var standardDownloadMbps: Double?
    public var standardUploadMbps: Double?
    /// Low-rate control loss probes when a packet-loss stress ran as a tool.
    public var lossProbes: [LossProbeResult]?
    public var notes: [String]

    public init() {
        recoveries = []
        notes = []
    }

    public var finalRecovery: RecoveryResult? { recoveries.last { $0.kind == "final" } }

    /// Highest *phase average* (never an instantaneous burst) under stress.
    public var maxStressDownloadMbps: Double? {
        ([streamRamp?.stages.map(\.throughput.averageMbps).max(), sustainedDownload?.throughput?.averageMbps,
          multiDestination.map(\.aggregateMbps), fullDuplex?.download?.averageMbps] as [Double?]).compactMap { $0 }.max()
    }
    public var maxStressUploadMbps: Double? {
        ([sustainedUpload?.throughput?.averageMbps, fullDuplex?.upload?.averageMbps] as [Double?]).compactMap { $0 }.max()
    }

    /// Worst control-latency inflation over the load phases (same probe as the idle baseline).
    public var worstLoadInflationMs: Double? {
        ([sustainedDownload?.latency?.inflationMs, sustainedUpload?.latency?.inflationMs, fullDuplex?.latency?.inflationMs,
          burst?.latencyInflationMs, multiDestination?.latency?.inflationMs] as [Double?]).compactMap { $0 }.max()
    }
}

/// Download-only vs upload-only vs both at once, all from the same node / method in one run.
public struct CrossLoadImpact: Codable, Sendable, Hashable {
    public var downloadOnlyMbps: Double?
    public var uploadOnlyMbps: Double?
    public var fullDuplexDownloadMbps: Double?
    public var fullDuplexUploadMbps: Double?
    public var downloadLossDueToUploadPercent: Double?
    public var uploadLossDueToDownloadPercent: Double?
    public var idleLatencyMs: Double?
    public var downloadLoadedLatencyMs: Double?
    public var uploadLoadedLatencyMs: Double?
    public var fullDuplexLoadedLatencyMs: Double?

    public static func make(_ r: StressLoadReport) -> CrossLoadImpact? {
        guard let fd = r.fullDuplex else { return nil }
        return CrossLoadImpact(downloadOnlyMbps: fd.downloadOnlyReferenceMbps, uploadOnlyMbps: fd.uploadOnlyReferenceMbps,
                               fullDuplexDownloadMbps: fd.download?.averageMbps, fullDuplexUploadMbps: fd.upload?.averageMbps,
                               downloadLossDueToUploadPercent: fd.downloadDegradationPercent,
                               uploadLossDueToDownloadPercent: fd.uploadDegradationPercent,
                               idleLatencyMs: r.idleControlMedianMs, downloadLoadedLatencyMs: r.sustainedDownload?.latency?.medianMs,
                               uploadLoadedLatencyMs: r.sustainedUpload?.latency?.medianMs, fullDuplexLoadedLatencyMs: fd.latency?.medianMs)
    }

    public init(downloadOnlyMbps: Double? = nil, uploadOnlyMbps: Double? = nil, fullDuplexDownloadMbps: Double? = nil, fullDuplexUploadMbps: Double? = nil, downloadLossDueToUploadPercent: Double? = nil, uploadLossDueToDownloadPercent: Double? = nil, idleLatencyMs: Double? = nil, downloadLoadedLatencyMs: Double? = nil, uploadLoadedLatencyMs: Double? = nil, fullDuplexLoadedLatencyMs: Double? = nil) {
        self.downloadOnlyMbps = downloadOnlyMbps
        self.uploadOnlyMbps = uploadOnlyMbps
        self.fullDuplexDownloadMbps = fullDuplexDownloadMbps
        self.fullDuplexUploadMbps = fullDuplexUploadMbps
        self.downloadLossDueToUploadPercent = downloadLossDueToUploadPercent
        self.uploadLossDueToDownloadPercent = uploadLossDueToDownloadPercent
        self.idleLatencyMs = idleLatencyMs
        self.downloadLoadedLatencyMs = downloadLoadedLatencyMs
        self.uploadLoadedLatencyMs = uploadLoadedLatencyMs
        self.fullDuplexLoadedLatencyMs = fullDuplexLoadedLatencyMs
    }
}

/// Stress sub-scores (0–100). Speed alone never earns a high score: latency under load, recovery
/// and stability dominate.
///
///     saturation_stability = 100 − max(0, degradation %) − (1 − p10 / median) × 50        (sustained, worst direction)
///     full_duplex          = 100 − mean(max(0, dl %, ul % degradation)) × 0.7 − inflation / 3
///     burst_resilience     = BurstResult.stabilityScore
///     recovery             = 100 − time_to_10 % (ms) / 100; incomplete → 30
///     loaded_latency       = 100 − worst inflation (ms) × 0.5
///     stress_endurance     = mean of the available scores
public struct StressLoadScores: Codable, Sendable, Hashable {
    public var saturationStability: Int?
    public var fullDuplex: Int?
    public var burstResilience: Int?
    public var recovery: Int?
    public var loadedLatency: Int?
    public var stressEndurance: Int?

    static func clamp(_ v: Double) -> Int { Int(max(0, min(100, v)).rounded()) }

    public static func make(_ r: StressLoadReport) -> StressLoadScores {
        var s = StressLoadScores()
        let sustained = [r.sustainedDownload?.throughput, r.sustainedUpload?.throughput].compactMap { $0 }
        if !sustained.isEmpty {
            s.saturationStability = sustained.map { t -> Int in
                let ratio = t.medianMbps > 0 && !t.samplingArtifact ? t.p10Mbps / t.medianMbps : 1
                return clamp(100 - max(0, t.degradationPercent ?? 0) - (1 - ratio) * 50)
            }.min()
        }
        if let fd = r.fullDuplex {
            let deg = [fd.downloadDegradationPercent, fd.uploadDegradationPercent].compactMap { $0 }.map { max(0, $0) }
            s.fullDuplex = clamp(100 - (Descriptive.mean(deg) ?? 0) * 0.7 - max(0, fd.latency?.inflationMs ?? 0) / 3)
        }
        s.burstResilience = r.burst?.stabilityScore.map(clamp)
        if let f = r.finalRecovery {
            s.recovery = f.complete ? clamp(100 - (f.recoveryTime10PercentMs ?? 0) / 100) : 30
        }
        if let w = r.worstLoadInflationMs { s.loadedLatency = clamp(100 - max(0, w) * 0.5) }
        let all = [s.saturationStability, s.fullDuplex, s.burstResilience, s.recovery, s.loadedLatency].compactMap { $0 }
        s.stressEndurance = all.isEmpty ? nil : Int((Double(all.reduce(0, +)) / Double(all.count)).rounded())
        return s
    }

    public init(saturationStability: Int? = nil, fullDuplex: Int? = nil, burstResilience: Int? = nil, recovery: Int? = nil, loadedLatency: Int? = nil, stressEndurance: Int? = nil) {
        self.saturationStability = saturationStability
        self.fullDuplex = fullDuplex
        self.burstResilience = burstResilience
        self.recovery = recovery
        self.loadedLatency = loadedLatency
        self.stressEndurance = stressEndurance
    }
}

extension StressLoadReport {
    public var crossLoadImpact: CrossLoadImpact? { CrossLoadImpact.make(self) }
    public var scores: StressLoadScores { StressLoadScores.make(self) }

    /// One plain-language sentence built only from measured values.
    public func summarySentence(standardDownloadMbps dl: Double?, standardUploadMbps ul: Double?) -> String {
        var parts: [String] = []
        if let dl, let ul { parts.append("正常下載約 \(Fmt.d(dl, 0)) Mbps、上傳約 \(Fmt.d(ul, 0)) Mbps") }
        if let ramp = streamRamp {
            if ramp.saturationDetected, let n = ramp.saturationStreamCount {
                parts.append("約 \(n) 條連線後已接近飽和")
            } else {
                parts.append("到 \(ramp.maxObservedStreamCount) 條連線仍在成長，尚未確認飽和點")
            }
        }
        if let d = sustainedDownload?.throughput?.degradationPercent {
            parts.append(abs(d) < 10 ? "持續下載穩定" : "持續下載期間速度下降約 \(Fmt.d(d, 0))%")
        }
        if let fd = fullDuplex, let inflation = fd.latency?.inflationMs {
            parts.append(inflation >= 50 ? "上下行同時滿載時延遲增加約 \(Fmt.d(inflation, 0)) ms" : "上下行同時滿載時延遲僅增加約 \(Fmt.d(max(0, inflation), 0)) ms")
        }
        if let r = burst?.medianRecoveryTimeMs { parts.append("突發負載後延遲約 \(Fmt.d(r, 0)) ms 恢復") }
        if let f = finalRecovery { parts.append(f.complete ? "負載結束後延遲可回到基準" : "測試時間內延遲未完全回到基準") }
        var s = parts.joined(separator: "；")
        if let w = worstLoadInflationMs {
            s += w >= 80 ? "。大量背景傳輸期間不建議進行低延遲遊戲或語音。" : (w < 30 ? "。負載下延遲控制良好，適合遊戲與語音。" : "。")
        } else if !s.isEmpty { s += "。" }
        return s
    }
}

// MARK: - Toolbox

/// Stress engines that can run alone from the toolbox.
public enum StressToolKind: String, Codable, Sendable, Hashable, CaseIterable {
    case streamRamp, sustainedDownload, sustainedUpload, fullDuplex, burst, multiDestination, recovery, packetLossStress

    public var title: String {
        switch self {
        case .streamRamp: "連線數階梯（飽和點）"
        case .sustainedDownload: "持續下載滿載"
        case .sustainedUpload: "持續上傳滿載"
        case .fullDuplex: "全雙工滿載"
        case .burst: "突發 / 階梯負載"
        case .multiDestination: "多目的地同時下載"
        case .recovery: "負載後恢復測試"
        case .packetLossStress: "封包遺失壓力"
        }
    }
}

/// Parameters of a toolbox stress run (the Extreme Stress Test chooses them automatically).
public struct StressToolRequest: Codable, Sendable, Hashable {
    public var kind: StressToolKind
    /// Load seconds (ramp: per stage; burst: ignored — cycles × (load + idle)).
    public var durationSeconds: Double
    public var maxStreams: Int
    public var burstCycles: Int
    /// Stress node id (nil = first HTTP node, e.g. Cloudflare).
    public var targetNodeID: String?
    /// Hard cap for this run (nil = the app's data policy).
    public var dataLimitBytes: Int64?

    public init(kind: StressToolKind, durationSeconds: Double = 20, maxStreams: Int = 32, burstCycles: Int = 10,
                targetNodeID: String? = nil, dataLimitBytes: Int64? = nil) {
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.maxStreams = maxStreams
        self.burstCycles = burstCycles
        self.targetNodeID = targetNodeID
        self.dataLimitBytes = dataLimitBytes
    }
}
