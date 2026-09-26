import Foundation

// MARK: - Loss confirmation

/// One loss probe of the stress test (the 50 pps ICMP stress probe or a low-rate control).
public struct LossProbeResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var target: String
    /// "icmpEcho", "udpEcho", "quicHandshake", "tcpConnect".
    public var method: String
    public var packetsPerSecond: Double
    public var isStressProbe: Bool
    public var statistics: LatencyStatistics
    public var samples: [LatencySample]

    public init(id: String, name: String, target: String, method: String, packetsPerSecond: Double, isStressProbe: Bool,
                samples: [LatencySample]) {
        self.id = id
        self.name = name
        self.target = target
        self.method = method
        self.packetsPerSecond = packetsPerSecond
        self.isStressProbe = isStressProbe
        self.samples = samples
        self.statistics = LatencyStatistics.compute(from: samples)
    }

    public var lossPercent: Double { statistics.loss.lossPercent }
    /// ICMP echo and UDP echo observe individual packets; handshake-based probes do not.
    public var isPacketLossProbe: Bool { Self.packetLossMethods.contains(method) }
    public static let packetLossMethods: Set<String> = ["icmpEcho", "udpEcho"]
    public var sent: Int { statistics.sent }
}

public enum LossVerdict: String, Codable, Sendable, Hashable {
    /// ≥ 2 independent control targets lost ≥ 1 % and the control median is ≥ 1 %.
    case confirmedGeneralPacketLoss
    /// Loss toward specific target(s) while at least one independent control target stayed clean.
    case endpointSpecificLossObserved
    /// Only the high-rate ICMP stress probe lost packets; its own low-rate control did not.
    case possibleICMPRateLimiting
    /// No loss on any valid control: no evidence of general packet loss (not a proof of zero loss).
    case noConfirmedGeneralPacketLoss
    /// Every control target lost a little but below the general threshold, a single control, or
    /// no usable control probe.
    case inconclusive
    /// Legacy values (results before v2.2) — still decoded, never produced.
    case confirmedLoss, noLoss

    public var displayName: String {
        switch self {
        case .confirmedGeneralPacketLoss, .confirmedLoss: "已確認廣泛性封包遺失（多個獨立端點一致）"
        case .endpointSpecificLossObserved: "僅特定端點觀察到遺失（其他獨立端點無遺失）"
        case .possibleICMPRateLimiting: "可能為 ICMP 限速（僅高頻壓力探測遺失）"
        case .noConfirmedGeneralPacketLoss, .noLoss: "無廣泛性封包遺失證據"
        case .inconclusive: "證據不足（遺失程度低或對照不足）"
        }
    }
}

public struct LossConfirmation: Codable, Sendable, Hashable {
    public var verdict: LossVerdict
    /// Loss of the 50 pps ICMP stress probe (may be ICMP rate limiting).
    public var stressLossPercent: Double?
    /// Median loss of the valid low-rate control probes — the general-loss figure the app reports.
    public var confirmedLossPercent: Double?
    public var validControlCount: Int
    public var lossyControlCount: Int
    /// Targets where loss was observed (controls and / or the stress probe); nil before v2.2.
    public var affectedTargets: [String]?
    /// Control targets without any loss.
    public var cleanTargets: [String]?

    public static let lossThresholdPercent = 1.0
    public static let minimumControlPackets = 20

    /// Rules (controls = low-rate ICMP / UDP echo with ≥ 20 packets; QUIC / TCP never count):
    ///
    ///     ≥ 2 control targets ≥ 1 % and median ≥ 1 %          → confirmedGeneralPacketLoss
    ///     some control target lost, another target clean        → endpointSpecificLossObserved
    ///     every control target lost (below the general rule)    → inconclusive
    ///     controls clean, stress probe lost                     → possibleICMPRateLimiting
    ///     nothing lost                                          → noConfirmedGeneralPacketLoss
    ///     no valid control, or only one control target          → inconclusive (unless nothing lost)
    public static func evaluate(stress: LossProbeResult?, controls: [LossProbeResult]) -> LossConfirmation {
        let valid = controls.filter { !$0.isStressProbe && $0.isPacketLossProbe && $0.sent >= minimumControlPackets }
        let stressLoss = stress.map(\.lossPercent)
        let stressLost = (stress?.statistics.loss.lost ?? 0) > 0
        guard !valid.isEmpty else {
            return LossConfirmation(verdict: .inconclusive, stressLossPercent: stressLoss, confirmedLossPercent: nil,
                                    validControlCount: 0, lossyControlCount: 0,
                                    affectedTargets: stressLost ? stress.map { [$0.target] } : nil, cleanTargets: [])
        }
        // Per target: worst loss of its controls.
        var byTarget: [String: Double] = [:]
        var lostByTarget: [String: Int] = [:]
        for c in valid {
            byTarget[c.target] = max(byTarget[c.target] ?? 0, c.lossPercent)
            lostByTarget[c.target, default: 0] += c.statistics.loss.lost
        }
        let targets = byTarget.keys.sorted()
        let affectedControls = targets.filter { (lostByTarget[$0] ?? 0) > 0 }
        let clean = targets.filter { (lostByTarget[$0] ?? 0) == 0 }
        let median = Descriptive.median(valid.map(\.lossPercent)) ?? 0
        let lossyTargets = targets.filter { (byTarget[$0] ?? 0) >= lossThresholdPercent }.count
        var affected = affectedControls
        if stressLost, let t = stress?.target, !affected.contains(t) { affected.append(t) }

        let verdict: LossVerdict
        if lossyTargets >= 2 && median >= lossThresholdPercent {
            verdict = .confirmedGeneralPacketLoss
        } else if !affectedControls.isEmpty && !clean.isEmpty {
            verdict = .endpointSpecificLossObserved
        } else if !affectedControls.isEmpty {
            verdict = .inconclusive
        } else if stressLost {
            verdict = targets.count >= 1 ? .possibleICMPRateLimiting : .inconclusive
        } else {
            verdict = .noConfirmedGeneralPacketLoss
        }
        return LossConfirmation(verdict: verdict, stressLossPercent: stressLoss, confirmedLossPercent: median,
                                validControlCount: valid.count, lossyControlCount: valid.filter { $0.lossPercent >= lossThresholdPercent }.count,
                                affectedTargets: affected, cleanTargets: clean)
    }
}

// MARK: - Cross-provider aggregate

public struct ServerThroughputValue: Codable, Sendable, Hashable, Identifiable {
    public var nodeID: String
    public var name: String
    public var provider: StressProvider
    public var mbps: Double
    /// Measurement method ("HTTP x16", "NDT7 WebSocket x1"); nil before v2.2.
    public var method: String?
    public var streamCount: Int?
    /// "HTTPS/TCP (URLSession)" or "WebSocket/TCP (NDT7)".
    public var transportProtocol: String?
    public var id: String { nodeID }

    public init(nodeID: String, name: String, provider: StressProvider, mbps: Double, method: String? = nil) {
        self.nodeID = nodeID
        self.name = name
        self.provider = provider
        self.mbps = mbps
        self.method = method
        self.streamCount = method.flatMap(Self.streams(in:))
        self.transportProtocol = method.map { $0.hasPrefix("NDT7") ? "WebSocket/TCP (NDT7)" : "HTTPS/TCP (URLSession)" }
    }

    /// "HTTP x16" → 16.
    static func streams(in method: String) -> Int? {
        method.split(separator: "x").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Throughput statistics across nodes (throughput-capable nodes only).
///
///     variance = population variance of per-node Mbps;  CV = σ / mean
///     large variance ⇔ ≥ 2 nodes and (CV > 0.35 or max / min ≥ 2)
public struct CrossProviderAggregate: Codable, Sendable, Hashable {
    public var direction: TransferDirection
    public var values: [ServerThroughputValue]
    public var meanMbps: Double
    public var medianMbps: Double
    public var minMbps: Double
    public var maxMbps: Double
    public var p10Mbps: Double
    public var p95Mbps: Double
    public var variance: Double
    public var coefficientOfVariation: Double?
    public var largeVariance: Bool
    /// True only when every node was measured with the same method and stream count; then the
    /// spread is a provider comparison. Otherwise it is method-dependent and only a range.
    public var methodEquivalent: Bool?

    public static let largeCV = 0.35
    /// max / min at which a method-dependent difference is called out (instead of just a range).
    public static let methodDifferenceRatio = 1.3

    public static func make(_ direction: TransferDirection, values: [ServerThroughputValue]) -> CrossProviderAggregate? {
        let v = values.map(\.mbps).filter(\.isFinite)
        guard !v.isEmpty, let mean = Descriptive.mean(v), let median = Descriptive.median(v) else { return nil }
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)
        let cv = mean > 0 ? variance.squareRoot() / mean : nil
        let lo = v.min()!, hi = v.max()!
        let large = v.count >= 2 && ((cv ?? 0) > largeCV || (lo > 0 ? hi / lo >= 2 : hi > 0))
        let methods = Set(values.map { "\($0.method ?? "?")|\($0.streamCount ?? 0)" })
        let equivalent = values.allSatisfy { $0.method != nil } ? methods.count <= 1 : nil
        return CrossProviderAggregate(direction: direction, values: values, meanMbps: mean, medianMbps: median, minMbps: lo, maxMbps: hi,
                                      p10Mbps: Percentile.value(0.10, in: v)!, p95Mbps: Percentile.value(0.95, in: v)!,
                                      variance: variance, coefficientOfVariation: cv, largeVariance: large, methodEquivalent: equivalent)
    }

    /// Consistency is only claimable between equivalent methods.
    public var isConsistent: Bool { values.count >= 2 && !largeVariance && methodEquivalent != false }
    /// Provider comparison statistics (mean / median / variance / CV) are meaningful.
    public var comparable: Bool { methodEquivalent != false }
}

// MARK: - Latency probe provenance / bufferbloat comparability

public struct ProbeDescriptor: Codable, Sendable, Hashable {
    public var target: String
    /// "icmpEcho", "httpPing", "tcpConnect".
    public var method: String
    /// "ICMP", "HTTPS/TCP", "TCP".
    public var protocolName: String
    /// "IPv4", "IPv6" or "system" (resolver-chosen).
    public var ipFamily: String

    /// Stable id of "same target + protocol + method + IP family": only values sharing it may be
    /// subtracted or compared (e.g. "icmpEcho|ICMP|8.8.8.8|IPv4").
    public var comparisonGroupID: String { "\(method)|\(protocolName)|\(target)|\(ipFamily)" }

    public init(target: String, method: String, protocolName: String, ipFamily: String) {
        self.target = target
        self.method = method
        self.protocolName = protocolName
        self.ipFamily = ipFamily
    }
}

public enum ComparisonQuality: String, Codable, Sendable, Hashable {
    /// Same probe method and fixed target for idle and loaded, target not itself under load.
    case full
    /// Mixed or loaded-server target: indicative only, never a high-confidence bufferbloat grade.
    case limited
}

/// Idle vs loaded latency for one direction, with the provenance needed to judge comparability.
public struct BufferbloatComparison: Codable, Sendable, Hashable {
    public var direction: TransferDirection
    /// "independentControlProbe" or "referenceProbe".
    public var source: String
    public var probe: ProbeDescriptor
    public var idleSampleCount: Int
    public var loadedSampleCount: Int
    public var idleMedianMs: Double
    public var loadedMedianMs: Double
    public var comparisonTargetSame: Bool
    public var comparisonMethodSame: Bool
    public var quality: ComparisonQuality
    public var note: String

    public var increaseMs: Double { max(0, loadedMedianMs - idleMedianMs) }
}

// MARK: - Per-node / per-round results

public struct StressTransferResult: Codable, Sendable, Hashable, Identifiable {
    public var nodeID: String
    public var round: Int
    public var direction: TransferDirection
    /// "HTTP x16" or "NDT7 WebSocket x1".
    public var method: String
    public var speed: SpeedResult?
    public var loadedLatency: LatencyStatistics?
    public var loadedSamples: [LatencySample]?
    /// Same-time samples of the independent control probe (fixed target, not under load).
    public var controlLoadedSamples: [LatencySample]?
    public var error: String?
    /// 1 = first try, 2 = retry after an invalid first attempt (nil in results before v2.1.2).
    public var attempt: Int?
    /// Validation outcome; set by the runner / `StressSummary` (nil = older result).
    public var validity: TransferValidity?
    public var id: String { "\(nodeID)-\(round)-\(direction.rawValue)-\(attempt ?? 1)" }

    public init(nodeID: String, round: Int, direction: TransferDirection, method: String, speed: SpeedResult?,
                loadedLatency: LatencyStatistics?, loadedSamples: [LatencySample]?, error: String?, attempt: Int = 1) {
        self.nodeID = nodeID
        self.round = round
        self.direction = direction
        self.method = method
        self.speed = speed
        self.loadedLatency = loadedLatency
        self.loadedSamples = loadedSamples
        self.error = error
        self.attempt = attempt
        self.validity = Self.baseValidity(speed: speed, error: error)
    }

    static func baseValidity(speed: SpeedResult?, error: String?) -> TransferValidity {
        guard let speed else { return .invalid(.endpointFailure, error ?? "未完成") }
        if let v = speed.validity, !v.valid { return v }
        if let error { return .invalid(.endpointFailure, error) }
        return speed.validity ?? TransferValidator.evaluate(speed)
    }

    public var bytes: Int64 { speed?.summary.totalBytes ?? 0 }
    public var isValid: Bool { validity?.valid ?? (speed != nil && error == nil) }
    /// Robust rate of a valid transfer (window median, or bytes / time when batched).
    /// Server-confirmed received bytes win over client counters (upload write-completion batching).
    public var rateMbps: Double? { isValid ? (speed?.serverConfirmed?.averageMbps ?? speed?.summary.robustMbps) : nil }

    public static let minimumLoadMbps = 1.0
    /// Loaded latency / bufferbloat need a transfer that really loaded the link.
    public var loadValid: Bool { isValid && (speed?.summary.averageMbps ?? 0) >= Self.minimumLoadMbps && loadedLatency?.rtt != nil }
}

public struct StressPhaseRecord: Codable, Sendable, Hashable, Identifiable {
    public var kind: StressPhaseKind
    public var round: Int?
    public var nodeID: String?
    public var plannedSeconds: Double
    public var startOffset: Double
    public var actualSeconds: Double
    public var downloadBytes: Int64
    public var uploadBytes: Int64
    public var note: String?
    public var id: String { "\(kind.rawValue)-\(round ?? 0)-\(nodeID ?? "")-\(startOffset)" }

    public init(kind: StressPhaseKind, round: Int?, nodeID: String?, plannedSeconds: Double, startOffset: Double, actualSeconds: Double,
                downloadBytes: Int64 = 0, uploadBytes: Int64 = 0, note: String? = nil) {
        self.kind = kind
        self.round = round
        self.nodeID = nodeID
        self.plannedSeconds = plannedSeconds
        self.startOffset = startOffset
        self.actualSeconds = actualSeconds
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.note = note
    }
}

public enum ScoreConfidence: String, Codable, Sendable, Hashable {
    case high, medium, low

    public var displayName: String {
        switch self {
        case .high: "高"
        case .medium: "中（部分量測無效或無法取得）"
        case .low: "低（關鍵量測無效）"
        }
    }
}

// MARK: - Summary

public struct StressSummary: Codable, Sendable, Hashable {
    public var testMode: String = "extremeStressTest"
    public var plan: StressTestPlan
    public var configuredSeconds: Double
    public var actualSeconds: Double
    /// Nodes with their health-check outcome.
    public var nodes: [StressNode]
    /// Every attempt, valid or not (invalid ones are kept as diagnostic evidence).
    public var transfers: [StressTransferResult]
    public var phases: [StressPhaseRecord]
    public var downloadAggregate: CrossProviderAggregate?
    public var uploadAggregate: CrossProviderAggregate?
    public var stressProbe: LossProbeResult?
    public var controlProbes: [LossProbeResult]
    public var lossConfirmation: LossConfirmation
    public var preLoadLatency: LatencyStatistics?
    public var preLoadSamples: [LatencySample]?
    /// Latency right after each round's load stopped.
    public var postLoadLatency: [LatencyStatistics]
    public var postLoadSamples: [[LatencySample]]
    /// Reference-path latency measured in time recycled from phases that finished early.
    public var extendedMonitoring: LatencyStatistics?
    public var extendedMonitoringSamples: [LatencySample]?
    /// Data limits in force and whether a cap stopped throughput phases early.
    public var dataLimits: StressDataLimits?
    public var dataCapReached: Bool?
    /// Traffic estimate shown before the start (point estimate; range = ±30 %); nil before v2.2.1.
    public var trafficEstimate: TrafficEstimate?
    /// Original / updated (observed-rate) / latest projection; nil before v2.4.0.
    public var trafficProjection: StressTrafficProjection?
    /// Independent control probe (fixed target never under load) sampled idle and during every load.
    public var controlProbe: ProbeDescriptor?
    public var controlIdleSamples: [LatencySample]?
    /// Reference probe (idle / recovery / monitoring path).
    public var referenceProbe: ProbeDescriptor?
    /// Seconds of unused phase budget that were spent on extra stress work (nil before v2.1.2).
    public var recycledSeconds: Double?
    public var totalDownloadBytes: Int64
    public var totalUploadBytes: Int64
    public var warnings: [String]
    public var score: Int?
    public var scoreConfidence: ScoreConfidence?
    /// Measurements left out of statistics and score, with the reason.
    public var excludedInvalidMetrics: [String]?

    public init(plan: StressTestPlan, configuredSeconds: Double, actualSeconds: Double, nodes: [StressNode], transfers: [StressTransferResult],
                phases: [StressPhaseRecord], stressProbe: LossProbeResult?, controlProbes: [LossProbeResult],
                preLoadLatency: LatencyStatistics?, preLoadSamples: [LatencySample]?, postLoadLatency: [LatencyStatistics],
                postLoadSamples: [[LatencySample]], warnings: [String], extendedMonitoringSamples: [LatencySample]? = nil,
                recycledSeconds: Double = 0, controlProbe: ProbeDescriptor? = nil, controlIdleSamples: [LatencySample]? = nil,
                referenceProbe: ProbeDescriptor? = nil) {
        self.controlProbe = controlProbe
        self.controlIdleSamples = controlIdleSamples
        self.referenceProbe = referenceProbe
        self.plan = plan
        self.configuredSeconds = configuredSeconds
        self.actualSeconds = actualSeconds
        self.nodes = nodes
        self.transfers = Self.crossCheck(transfers)
        self.phases = phases
        self.stressProbe = stressProbe
        self.controlProbes = controlProbes
        self.lossConfirmation = LossConfirmation.evaluate(stress: stressProbe, controls: controlProbes)
        self.preLoadLatency = preLoadLatency
        self.preLoadSamples = preLoadSamples
        self.postLoadLatency = postLoadLatency
        self.postLoadSamples = postLoadSamples
        self.extendedMonitoringSamples = extendedMonitoringSamples
        self.extendedMonitoring = extendedMonitoringSamples.flatMap { $0.isEmpty ? nil : LatencyStatistics.compute(from: $0) }
        self.recycledSeconds = recycledSeconds
        self.warnings = warnings
        // Traffic totals count every attempt (that data really moved); statistics use valid ones only.
        self.totalDownloadBytes = transfers.filter { $0.direction == .download }.reduce(0) { $0 + $1.bytes }
        self.totalUploadBytes = transfers.filter { $0.direction == .upload }.reduce(0) { $0 + $1.bytes }
        self.scoreConfidence = .high
        self.excludedInvalidMetrics = []
        self.downloadAggregate = CrossProviderAggregate.make(.download, values: Self.perNode(.download, self.transfers, nodes))
        self.uploadAggregate = CrossProviderAggregate.make(.upload, values: Self.perNode(.upload, self.transfers, nodes))
        self.excludedInvalidMetrics = excludedMetrics()
        self.scoreConfidence = confidence()
        self.score = StressScore.compute(self)
    }

    public var totalBytes: Int64 { totalDownloadBytes + totalUploadBytes }

    /// Marks a self-consistent-looking transfer invalid when it moved < 1 % of what the same node
    /// sustained in its other valid attempts in that direction and < 1 Mbps (unexpected tiny body).
    static func crossCheck(_ transfers: [StressTransferResult]) -> [StressTransferResult] {
        transfers.map { t in
            guard t.isValid, let rate = t.speed?.summary.averageMbps else { return t }
            let peers = transfers.filter { $0.nodeID == t.nodeID && $0.direction == t.direction && $0.id != t.id && $0.isValid }
                .compactMap { $0.speed?.summary.averageMbps }
            guard let best = peers.max(), rate < 1, rate < best * 0.01 else { return t }
            var c = t
            c.validity = .invalid(.insufficientPayload, "僅 \(Fmt.d(rate, 3)) Mbps，不到同節點其他輪（\(Fmt.d(best, 0)) Mbps）的 1%")
            return c
        }
    }

    /// Per node: mean over valid attempts of the robust rate. Throughput-capable nodes only.
    static func perNode(_ direction: TransferDirection, _ transfers: [StressTransferResult], _ nodes: [StressNode]) -> [ServerThroughputValue] {
        nodes.filter(\.isThroughputCapable).compactMap { node in
            let rates = transfers.filter { $0.nodeID == node.id && $0.direction == direction }.compactMap(\.rateMbps)
            guard let mean = Descriptive.mean(rates) else { return nil }
            let method = transfers.first { $0.nodeID == node.id && $0.direction == direction && $0.isValid }?.method
            return ServerThroughputValue(nodeID: node.id, name: node.name, provider: node.provider, mbps: mean, method: method)
        }
    }

    /// Primary speed test node: the first HTTP multi-stream node of the plan (validation providers
    /// such as M-Lab NDT7 are reported separately, never averaged into the headline).
    public var primaryNodeID: String? {
        (plan.throughputNodes.first { $0.provider != .mlab } ?? plan.throughputNodes.first)?.id
    }

    /// Headline rate: cross-node median when all methods are equivalent, otherwise the primary
    /// node's own result (validation providers stay separate).
    public func headlineMbps(_ direction: TransferDirection) -> Double? {
        guard let agg = direction == .download ? downloadAggregate : uploadAggregate else { return nil }
        if agg.comparable { return agg.medianMbps }
        return agg.values.first { $0.nodeID == primaryNodeID }?.mbps ?? agg.values.first?.mbps
    }

    /// "cross_provider_median" or "primary_method".
    public func headlineScope(_ direction: TransferDirection) -> String {
        let agg = direction == .download ? downloadAggregate : uploadAggregate
        return agg?.comparable == false ? "primary_method" : "cross_provider_median"
    }

    /// Valid transfers of a direction (the only ones any statistic may use).
    public func transfers(_ direction: TransferDirection) -> [StressTransferResult] {
        transfers.filter { $0.direction == direction && $0.isValid && $0.speed != nil }
    }

    public func invalidTransfers() -> [StressTransferResult] { transfers.filter { !$0.isValid } }

    /// Planned node × round × direction slots that never produced a valid transfer (even after retry).
    public func failedSlots() -> [StressTransferResult] {
        let groups = Dictionary(grouping: transfers) { "\($0.nodeID)-\($0.round)-\($0.direction.rawValue)" }
        return groups.values.compactMap { g in g.contains(where: \.isValid) ? nil : g.max { ($0.attempt ?? 1) < ($1.attempt ?? 1) } }
            .sorted { ($0.round, $0.nodeID) < ($1.round, $1.nodeID) }
    }

    /// Mean window stability over valid transfers whose short windows are reliable; nil when none.
    public func stability(_ direction: TransferDirection) -> Double? {
        Descriptive.mean(transfers(direction).compactMap { $0.speed?.bestStabilityScore })
    }

    /// "measurementSamplingArtifact" when valid transfers exist but none has reliable short windows.
    public func stabilityUnavailableReason(_ direction: TransferDirection) -> String? {
        let valid = transfers(direction)
        guard stability(direction) == nil else { return nil }
        if valid.isEmpty { return "noValidTransfer" }
        return valid.contains { $0.speed?.summary.shortWindowReliable == false } ? "measurementSamplingArtifact" : "insufficientSamples"
    }

    /// Transfers that generated meaningful load (valid, ≥ 1 Mbps, loaded latency measured).
    public func loadValidTransfers(_ direction: TransferDirection) -> [StressTransferResult] {
        transfers.filter { $0.direction == direction && $0.loadValid }
    }

    /// Loaded latency of a direction, valid loads only: median of the pooled raw samples (the same
    /// numbers the export's generic loaded-latency section shows), else median of per-transfer medians.
    public func loadedLatencyMs(_ direction: TransferDirection) -> Double? {
        let pooled = pooledLoadedSamples(direction)
        if let m = LatencyStatistics.compute(from: pooled).rtt?.median, !pooled.isEmpty { return m }
        return Descriptive.median(loadValidTransfers(direction).compactMap { $0.loadedLatency?.rtt?.median })
    }

    /// All loaded-latency samples of load-valid transfers of a direction (pooled).
    public func pooledLoadedSamples(_ direction: TransferDirection) -> [LatencySample] {
        var seq = 0
        return loadValidTransfers(direction).flatMap { t in
            (t.loadedSamples ?? []).filter { $0.offset >= 1.0 }.map { s -> LatencySample in
                defer { seq += 1 }
                return LatencySample(sequence: seq, offset: s.offset, rttMs: s.rttMs)
            }
        }
    }

    /// Control-probe samples during load-valid transfers of a direction (ramp-up excluded), resequenced.
    public func pooledControlSamples(_ direction: TransferDirection) -> [LatencySample] {
        var seq = 0
        return loadValidTransfers(direction).flatMap { t in
            (t.controlLoadedSamples ?? []).filter { $0.offset >= 1.0 }.map { s -> LatencySample in
                defer { seq += 1 }
                return LatencySample(sequence: seq, offset: s.offset, rttMs: s.rttMs)
            }
        }
    }

    /// Idle vs loaded comparison for a direction, valid loads only. Preference:
    ///
    ///  1. independent control probe — same method, same fixed target idle and loaded, target not
    ///     under load → quality full
    ///  2. reference probe — same method / target, but the target is a load server and loads came
    ///     from several providers → quality limited (indicative only)
    public func bufferbloatComparison(_ direction: TransferDirection) -> BufferbloatComparison? {
        let loads = loadValidTransfers(direction)
        guard !loads.isEmpty else { return nil }
        if let probe = controlProbe, let idle = controlIdleSamples, !idle.isEmpty {
            let loaded = pooledControlSamples(direction)
            if let i = LatencyStatistics.compute(from: idle).rtt?.median, let l = LatencyStatistics.compute(from: loaded).rtt?.median, !loaded.isEmpty {
                return BufferbloatComparison(direction: direction, source: "independentControlProbe", probe: probe,
                                             idleSampleCount: idle.count, loadedSampleCount: loaded.count, idleMedianMs: i, loadedMedianMs: l,
                                             comparisonTargetSame: true, comparisonMethodSame: true, quality: .full,
                                             note: "same probe method and fixed target (not under load) for idle and loaded")
            }
        }
        guard let idle = preLoadLatency?.rtt?.median, let loaded = loadedLatencyMs(direction) else { return nil }
        let providers = Set(loads.map(\.nodeID))
        let probe = referenceProbe ?? ProbeDescriptor(target: "unknown", method: "unknown", protocolName: "unknown", ipFamily: "unknown")
        let targetIsLoaded = plan.throughputNodes.contains { $0.host == probe.target }
        return BufferbloatComparison(direction: direction, source: "referenceProbe", probe: probe,
                                     idleSampleCount: preLoadSamples?.count ?? preLoadLatency?.sent ?? 0,
                                     loadedSampleCount: pooledLoadedSamples(direction).count,
                                     idleMedianMs: idle, loadedMedianMs: loaded,
                                     comparisonTargetSame: referenceProbe != nil, comparisonMethodSame: referenceProbe != nil, quality: .limited,
                                     note: (targetIsLoaded ? "probe target is also a load server (server-side queueing possible); " : "")
                                        + (providers.count > 1 ? "loads from \(providers.count) providers pooled; " : "")
                                        + "no independent control probe — indicative only")
    }

    /// Loaded − idle median for one direction (from `bufferbloatComparison`); nil without a valid load.
    public func loadedLatencyIncreaseMs(_ direction: TransferDirection) -> Double? {
        bufferbloatComparison(direction)?.increaseMs
    }

    /// Worst loaded − idle median (queueing under load), valid loads only.
    public var bufferbloatMs: Double? {
        [loadedLatencyIncreaseMs(.download), loadedLatencyIncreaseMs(.upload)].compactMap { $0 }.max()
    }

    /// Post-load median − pre-load median, worst round.
    public var recoveryDeltaMs: Double? {
        guard let idle = preLoadLatency?.rtt?.median else { return nil }
        return postLoadLatency.compactMap { $0.rtt?.median }.max().map { $0 - idle }
    }

    /// Download degradation from the first to the last round with valid data (%, positive = slower later).
    ///
    ///     (mean(first round) − mean(last round)) / mean(first round) × 100, valid transfers of nodes present in both
    public var throughputDegradationPercent: Double? {
        let valid = transfers(.download)
        guard let firstRound = valid.map(\.round).min(), let lastRound = valid.map(\.round).max(), lastRound > firstRound else { return nil }
        let first = valid.filter { $0.round == firstRound }
        let last = valid.filter { $0.round == lastRound }
        let common = Set(first.map(\.nodeID)).intersection(last.map(\.nodeID))
        let a = Descriptive.mean(first.filter { common.contains($0.nodeID) }.compactMap(\.rateMbps))
        let b = Descriptive.mean(last.filter { common.contains($0.nodeID) }.compactMap(\.rateMbps))
        guard let a, let b, a > 0 else { return nil }
        return (a - b) / a * 100
    }

    public var phaseDurations: [(kind: StressPhaseKind, seconds: Double)] {
        var order: [StressPhaseKind] = []
        var sums: [StressPhaseKind: Double] = [:]
        for p in phases {
            if sums[p.kind] == nil { order.append(p.kind) }
            sums[p.kind, default: 0] += p.actualSeconds
        }
        return order.map { ($0, sums[$0]!) }
    }

    func excludedMetrics() -> [String] {
        var out: [String] = []
        for t in invalidTransfers() {
            out.append("transfer \(t.nodeID) round \(t.round) \(t.direction.rawValue) attempt \(t.attempt ?? 1): \(t.validity?.reason?.rawValue ?? "invalid")")
        }
        for d in TransferDirection.allCases {
            if let r = stabilityUnavailableReason(d), !transfers(d).isEmpty { out.append("\(d.rawValue) stability: \(r)") }
            let valid = transfers(d).count, loadValid = loadValidTransfers(d).count
            if valid > loadValid { out.append("\(d.rawValue) loaded latency: \(valid - loadValid) transfer(s) insufficientLoad") }
        }
        let quic = controlProbes.filter { !$0.isPacketLossProbe }
        if !quic.isEmpty { out.append("loss verdict: \(quic.count) handshake probe(s) not packet-loss probes") }
        return out
    }

    /// high: every planned slot valid, stability and loss available · low: no valid download or
    /// upload, or < 50 % of slots valid · otherwise medium.
    func confidence() -> ScoreConfidence {
        let slots = Set(transfers.map { "\($0.nodeID)-\($0.round)-\($0.direction.rawValue)" }).count
        let failed = failedSlots().count
        if downloadAggregate == nil || uploadAggregate == nil || (slots > 0 && Double(failed) / Double(slots) > 0.5) { return .low }
        if failed > 0 || !invalidTransfers().isEmpty || stability(.download) == nil || stability(.upload) == nil
            || lossConfirmation.verdict == .inconclusive || bufferbloatMs == nil {
            return .medium
        }
        return .high
    }

    public static let slowRecoveryMs = 20.0
    public static let degradationPercent = 20.0
}

// MARK: - Score

/// Overall stress score (0–100): weighted mean of available components, weights renormalised.
/// Invalid transfers, loads without real throughput and artifact-contaminated stability never
/// enter a component; they lower `scoreConfidence` instead of the score.
///
///     throughput   20 %  mean(download curve(agg median), upload curve(agg median))
///     stability    15 %  mean(download, upload reliable window stability)
///     loaded lat.  15 %  latency curve(worst loaded median, valid loads)
///     bufferbloat  10 %  bufferbloat curve(worst loaded − idle, valid loads)
///     jitter        5 %  jitter curve(pre-load jitter)
///     loss         15 %  loss curve(confirmed control loss) — never the stress-only ICMP loss
///     consistency  10 %  CV curve: 0 → 100, 0.2 → 85, 0.35 → 65, 0.6 → 35, ≥ 1 → 0
///     recovery      5 %  post-load Δ: ≤ 5 → 100, 20 → 80, 50 → 50, ≥ 150 → 0
///     degradation   5 %  first → last round drop: ≤ 5 % → 100, 20 % → 60, ≥ 50 % → 0
public enum StressScore {
    static let consistency = ScoreCurve([(0, 100), (0.2, 85), (0.35, 65), (0.6, 35), (1, 0)])
    static let recovery = ScoreCurve([(0, 100), (5, 100), (20, 80), (50, 50), (150, 0)])
    static let degradation = ScoreCurve([(0, 100), (5, 100), (20, 60), (50, 0)])

    public static func compute(_ s: StressSummary) -> Int? {
        var parts: [(Double, Double)] = []
        let dl = s.headlineMbps(.download), ul = s.headlineMbps(.upload)
        let tp = [dl.map { ScoreCurve.download.score($0) }, ul.map { ScoreCurve.upload.score($0) }].compactMap { $0 }
        if let v = Descriptive.mean(tp) { parts.append((v, 0.20)) }
        if let v = Descriptive.mean([s.stability(.download), s.stability(.upload)].compactMap { $0 }) { parts.append((v, 0.15)) }
        if let v = [s.loadedLatencyMs(.download), s.loadedLatencyMs(.upload)].compactMap({ $0 }).max() {
            parts.append((ScoreCurve.latency.score(v), 0.15))
        }
        if let v = s.bufferbloatMs { parts.append((ScoreCurve.bufferbloat.score(v), 0.10)) }
        if let v = s.preLoadLatency?.rtt?.jitter { parts.append((ScoreCurve.jitter.score(v), 0.05)) }
        if let v = s.lossConfirmation.confirmedLossPercent { parts.append((ScoreCurve.loss.score(v), 0.15)) }
        // Consistency only between equivalent methods (a method-dependent spread is not inconsistency).
        let cvs = [s.downloadAggregate, s.uploadAggregate].compactMap { $0 }.filter { $0.values.count >= 2 && $0.comparable }
            .compactMap(\.coefficientOfVariation)
        if let v = cvs.max() { parts.append((consistency.score(v), 0.10)) }
        if let v = s.recoveryDeltaMs { parts.append((recovery.score(max(0, v)), 0.05)) }
        if let v = s.throughputDegradationPercent { parts.append((degradation.score(max(0, v)), 0.05)) }
        let weight = parts.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { return nil }
        return Int((parts.reduce(0) { $0 + $1.0 * $1.1 } / weight).rounded())
    }
}
