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
    /// ≥ 2 independent control probes lost ≥ 1 % and their median is ≥ 1 %.
    case confirmedLoss
    /// Only the high-rate ICMP stress probe lost packets; low-rate controls did not.
    case possibleICMPRateLimiting
    /// No probe lost ≥ 1 %.
    case noLoss
    /// A single lossy control, or no usable control probe.
    case inconclusive

    public var displayName: String {
        switch self {
        case .confirmedLoss: "已確認封包遺失（多探測一致）"
        case .possibleICMPRateLimiting: "可能為 ICMP 限速（僅高頻壓力探測遺失）"
        case .noLoss: "未觀察到遺失"
        case .inconclusive: "證據不足（僅單一探測遺失或對照不足）"
        }
    }
}

public struct LossConfirmation: Codable, Sendable, Hashable {
    public var verdict: LossVerdict
    /// Loss of the 50 pps ICMP stress probe (may be ICMP rate limiting).
    public var stressLossPercent: Double?
    /// Median loss of the valid low-rate control probes — the loss figure the app reports.
    public var confirmedLossPercent: Double?
    public var validControlCount: Int
    public var lossyControlCount: Int

    public static let lossThresholdPercent = 1.0
    public static let minimumControlPackets = 20

    /// See `LossVerdict` for the rules. Controls with fewer than 20 packets are ignored.
    public static func evaluate(stress: LossProbeResult?, controls: [LossProbeResult]) -> LossConfirmation {
        // Only probes that can observe packet loss count: a failed QUIC / TCP handshake is a
        // protocol or endpoint result, not a lost packet.
        let valid = controls.filter { !$0.isStressProbe && $0.isPacketLossProbe && $0.sent >= minimumControlPackets }
        let stressLoss = stress.map(\.lossPercent)
        guard !valid.isEmpty else {
            return LossConfirmation(verdict: .inconclusive, stressLossPercent: stressLoss, confirmedLossPercent: nil,
                                    validControlCount: 0, lossyControlCount: 0)
        }
        let losses = valid.map(\.lossPercent)
        let median = Descriptive.median(losses) ?? 0
        let lossy = losses.filter { $0 >= lossThresholdPercent }.count
        let verdict: LossVerdict
        if lossy >= 2 && median >= lossThresholdPercent {
            verdict = .confirmedLoss
        } else if lossy >= 1 {
            verdict = .inconclusive
        } else if let stressLoss, stressLoss >= lossThresholdPercent {
            verdict = .possibleICMPRateLimiting
        } else {
            verdict = .noLoss
        }
        return LossConfirmation(verdict: verdict, stressLossPercent: stressLoss, confirmedLossPercent: median,
                                validControlCount: valid.count, lossyControlCount: lossy)
    }
}

// MARK: - Cross-provider aggregate

public struct ServerThroughputValue: Codable, Sendable, Hashable, Identifiable {
    public var nodeID: String
    public var name: String
    public var provider: StressProvider
    public var mbps: Double
    public var id: String { nodeID }

    public init(nodeID: String, name: String, provider: StressProvider, mbps: Double) {
        self.nodeID = nodeID
        self.name = name
        self.provider = provider
        self.mbps = mbps
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

    public static let largeCV = 0.35

    public static func make(_ direction: TransferDirection, values: [ServerThroughputValue]) -> CrossProviderAggregate? {
        let v = values.map(\.mbps).filter(\.isFinite)
        guard !v.isEmpty, let mean = Descriptive.mean(v), let median = Descriptive.median(v) else { return nil }
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)
        let cv = mean > 0 ? variance.squareRoot() / mean : nil
        let lo = v.min()!, hi = v.max()!
        let large = v.count >= 2 && ((cv ?? 0) > largeCV || (lo > 0 ? hi / lo >= 2 : hi > 0))
        return CrossProviderAggregate(direction: direction, values: values, meanMbps: mean, medianMbps: median, minMbps: lo, maxMbps: hi,
                                      p10Mbps: Percentile.value(0.10, in: v)!, p95Mbps: Percentile.value(0.95, in: v)!,
                                      variance: variance, coefficientOfVariation: cv, largeVariance: large)
    }

    public var isConsistent: Bool { values.count >= 2 && !largeVariance }
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
    public var rateMbps: Double? { isValid ? speed?.summary.robustMbps : nil }

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
                recycledSeconds: Double = 0) {
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
            return ServerThroughputValue(nodeID: node.id, name: node.name, provider: node.provider, mbps: mean)
        }
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
        Descriptive.mean(transfers(direction).compactMap { $0.speed?.summary.reliableStabilityScore })
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

    /// Loaded − idle median for one direction; nil (unavailable) without a valid load.
    public func loadedLatencyIncreaseMs(_ direction: TransferDirection) -> Double? {
        guard let idle = preLoadLatency?.rtt?.median, let loaded = loadedLatencyMs(direction) else { return nil }
        return max(0, loaded - idle)
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
        let dl = s.downloadAggregate?.medianMbps, ul = s.uploadAggregate?.medianMbps
        let tp = [dl.map { ScoreCurve.download.score($0) }, ul.map { ScoreCurve.upload.score($0) }].compactMap { $0 }
        if let v = Descriptive.mean(tp) { parts.append((v, 0.20)) }
        if let v = Descriptive.mean([s.stability(.download), s.stability(.upload)].compactMap { $0 }) { parts.append((v, 0.15)) }
        if let v = [s.loadedLatencyMs(.download), s.loadedLatencyMs(.upload)].compactMap({ $0 }).max() {
            parts.append((ScoreCurve.latency.score(v), 0.15))
        }
        if let v = s.bufferbloatMs { parts.append((ScoreCurve.bufferbloat.score(v), 0.10)) }
        if let v = s.preLoadLatency?.rtt?.jitter { parts.append((ScoreCurve.jitter.score(v), 0.05)) }
        if let v = s.lossConfirmation.confirmedLossPercent { parts.append((ScoreCurve.loss.score(v), 0.15)) }
        let cvs = [s.downloadAggregate, s.uploadAggregate].compactMap { $0 }.filter { $0.values.count >= 2 }.compactMap(\.coefficientOfVariation)
        if let v = cvs.max() { parts.append((consistency.score(v), 0.10)) }
        if let v = s.recoveryDeltaMs { parts.append((recovery.score(max(0, v)), 0.05)) }
        if let v = s.throughputDegradationPercent { parts.append((degradation.score(max(0, v)), 0.05)) }
        let weight = parts.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { return nil }
        return Int((parts.reduce(0) { $0 + $1.0 * $1.1 } / weight).rounded())
    }
}
