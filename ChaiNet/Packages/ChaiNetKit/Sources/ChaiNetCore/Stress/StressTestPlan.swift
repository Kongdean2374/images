import Foundation

// MARK: - Nodes

/// What a stress-test node may be used for.
public enum StressNodeCapability: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case throughput, latency, loss, tcp, tls, http, dns, quic, route, udpEcho

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum StressProvider: String, Codable, Sendable, Hashable, CaseIterable {
    case cloudflare, mlab, chainet, google, apple, quad9

    public var displayName: String {
        switch self {
        case .cloudflare: "Cloudflare Speed"
        case .mlab: "M-Lab NDT7"
        case .chainet: "ChaiNet 自架伺服器"
        case .google: "Google"
        case .apple: "Apple"
        case .quad9: "Quad9"
        }
    }

    /// Only these providers operate endpoints meant for bulk transfer. Google / Apple / Quad9 /
    /// DNS resolvers are never used for download / upload stress.
    public var allowsThroughput: Bool { [.cloudflare, .mlab, .chainet].contains(self) }
}

public struct StressNode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var provider: StressProvider
    public var host: String
    public var capabilities: Set<StressNodeCapability>
    /// Throughput endpoint (nil for latency-only nodes).
    public var server: ServerDescriptor?
    /// Pre-test health check (nil = not checked yet).
    public var healthy: Bool?
    public var healthLatencyMs: Double?
    public var healthDetail: String?

    public init(id: String, name: String, provider: StressProvider, host: String, capabilities: Set<StressNodeCapability>,
                server: ServerDescriptor? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.host = host
        // Enforced here so no code path can bulk-transfer against a latency-only provider.
        var caps = capabilities
        if !provider.allowsThroughput || server == nil { caps.remove(.throughput) }
        self.capabilities = caps
        self.server = server
    }

    public var isThroughputCapable: Bool { capabilities.contains(.throughput) }
    public var capabilityList: String { capabilities.sorted().map(\.rawValue).joined(separator: "|") }

    /// Built-in latency / protocol-only nodes (independent operators for control probes).
    public static let latencyOnlyDefaults: [StressNode] = [
        StressNode(id: "google-dns", name: "Google Public DNS", provider: .google, host: "8.8.8.8",
                   capabilities: [.latency, .loss, .tcp, .dns]),
        StressNode(id: "quad9-dns", name: "Quad9", provider: .quad9, host: "9.9.9.9",
                   capabilities: [.latency, .loss, .tcp, .dns]),
        StressNode(id: "google-web", name: "Google Web", provider: .google, host: "www.google.com",
                   capabilities: [.latency, .tcp, .tls, .http, .quic]),
        StressNode(id: "apple-web", name: "Apple", provider: .apple, host: "www.apple.com",
                   capabilities: [.latency, .tcp, .tls, .http, .route]),
    ]

    public static func throughputNode(for server: ServerDescriptor) -> StressNode {
        switch server.kind {
        case .cloudflare:
            StressNode(id: server.id, name: server.name, provider: .cloudflare, host: server.host,
                       capabilities: [.throughput, .latency, .loss, .tcp, .tls, .http, .quic, .route], server: server)
        case .mlabNDT7:
            StressNode(id: server.id, name: server.name, provider: .mlab, host: server.host,
                       capabilities: [.throughput, .latency, .tcp, .tls], server: server)
        case .chainet:
            StressNode(id: server.id, name: server.name, provider: .chainet, host: server.host,
                       capabilities: [.throughput, .latency, .loss, .tcp, .tls, .http, .udpEcho], server: server)
        }
    }
}

// MARK: - Budget recycling

/// Keeps the actual duration close to the configured one. Phases that finish early (DNS,
/// protocols, a failed node…) leave budget; it is spent on more stress, never dropped:
///
///     remaining ≥ one full round + 2 s  and  extra rounds < 3   → another throughput round
///     otherwise remaining ≥ 3 s                                  → extended monitoring (remaining − 1 s)
///     otherwise                                                  → done
public enum StressBudget {
    public enum Action: Equatable, Sendable {
        case extraRound
        case extendedMonitoring(seconds: Double)
        case done
    }
    public static let maxExtraRounds = 3

    public static func next(remaining: Double, roundCost: Double, extraRoundsDone: Int) -> Action {
        if roundCost > 0, remaining >= roundCost + 2, extraRoundsDone < maxExtraRounds { return .extraRound }
        if remaining >= 3 { return .extendedMonitoring(seconds: remaining - 1) }
        return .done
    }
}

// MARK: - Plan

public enum StressPhaseKind: String, Codable, Sendable, Hashable, CaseIterable {
    case healthCheck, warmUp, idleLatency, downloadStress, uploadStress, postLoadRecovery, packetLossStress,
         monitoring, dnsProtocols, ipFamilies, crossServerValidation, routeMTU, extendedMonitoring
    // v3.0: stress phases after the standard throughput.
    case streamRamp, sustainedDownload, sustainedUpload, fullDuplex, burst, multiDestination, shortRecovery, finalRecovery

    /// Share of the phase that loads each direction (traffic estimate / projection).
    public var loadShare: (download: Double, upload: Double) {
        switch self {
        case .downloadStress, .streamRamp, .sustainedDownload, .multiDestination: (1, 0)
        case .uploadStress, .sustainedUpload: (0, 1)
        case .fullDuplex: (1, 1)
        case .burst: (0.6, 0)
        default: (0, 0)
        }
    }

    public var isLoadPhase: Bool { loadShare.download > 0 || loadShare.upload > 0 }

    public var title: String {
        switch self {
        case .healthCheck: "節點健康檢查"
        case .warmUp: "暖機"
        case .idleLatency: "閒置延遲（負載前）"
        case .downloadStress: "下載壓力 + 負載延遲"
        case .uploadStress: "上傳壓力 + 負載延遲"
        case .postLoadRecovery: "冷卻 / 負載後恢復"
        case .packetLossStress: "封包遺失壓力（50 pps + 對照探測）"
        case .monitoring: "穩定度監測"
        case .dnsProtocols: "DNS / TCP / TLS / HTTP / QUIC"
        case .ipFamilies: "IPv4 / IPv6"
        case .crossServerValidation: "跨節點驗證"
        case .routeMTU: "路由追蹤 / MTU"
        case .extendedMonitoring: "最終延長觀察"
        case .streamRamp: "連線數階梯（飽和點搜尋）"
        case .sustainedDownload: "持續下載滿載"
        case .sustainedUpload: "持續上傳滿載"
        case .fullDuplex: "全雙工（上下行同時滿載）"
        case .burst: "突發負載（負載 / 閒置循環）"
        case .multiDestination: "多目的地同時下載"
        case .shortRecovery: "短恢復"
        case .finalRecovery: "最終恢復"
        }
    }
}

public struct StressPlanPhase: Codable, Sendable, Hashable, Identifiable {
    public var kind: StressPhaseKind
    /// 1-based round for repeated phases.
    public var round: Int?
    public var nodeID: String?
    public var seconds: Double
    public var id: String { "\(kind.rawValue)-\(round ?? 0)-\(nodeID ?? "")" }
}

public struct TrafficEstimate: Codable, Sendable, Hashable {
    public var downloadBytes: Int64
    public var uploadBytes: Int64
    public var assumedDownloadMbps: Double
    public var assumedUploadMbps: Double
    /// Upper bound: what a fast link of this network type could move in the same transfer time
    /// (nil in estimates made before v2.4.0).
    public var ceilingBytes: Int64?
    public var ceilingDownloadMbps: Double?
    public var ceilingUploadMbps: Double?

    public init(downloadBytes: Int64, uploadBytes: Int64, assumedDownloadMbps: Double, assumedUploadMbps: Double,
                ceilingBytes: Int64? = nil, ceilingDownloadMbps: Double? = nil, ceilingUploadMbps: Double? = nil) {
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.assumedDownloadMbps = assumedDownloadMbps
        self.assumedUploadMbps = assumedUploadMbps
        self.ceilingBytes = ceilingBytes
        self.ceilingDownloadMbps = ceilingDownloadMbps
        self.ceilingUploadMbps = ceilingUploadMbps
    }

    public var totalBytes: Int64 { downloadBytes + uploadBytes }
    /// Range shown to the user: 70 % of the conservative point estimate up to
    /// max(130 % of it, the network type's fast-link ceiling).
    public var lowBytes: Int64 { Int64(Double(totalBytes) * 0.7) }
    public var highBytes: Int64 { max(Int64(Double(totalBytes) * 1.3), ceilingBytes ?? 0) }
}

/// Traffic projection during an Extreme Stress Test: the pre-test estimate, the estimate updated
/// from the throughput actually observed (after round 1) and the actual usage.
///
///     projected = bytes used so far + Σ_direction remaining planned transfer seconds × observed Mbps / 8
///     observed Mbps = Σ bytes / Σ duration of valid transfers of that direction
public struct StressTrafficProjection: Codable, Sendable, Hashable {
    public var originalEstimateBytes: Int64?
    public var originalRangeLowBytes: Int64?
    public var originalRangeHighBytes: Int64?
    public var updatedEstimateBytes: Int64?
    /// e.g. "afterRound1"
    public var updatedBasis: String?
    public var observedDownloadMbps: Double?
    public var observedUploadMbps: Double?
    /// Latest live projection (includes budget-recycled extra rounds once they start).
    public var latestProjectionBytes: Int64?
    public var warning: String?

    public init(original: TrafficEstimate?) {
        originalEstimateBytes = original?.totalBytes
        originalRangeLowBytes = original?.lowBytes
        originalRangeHighBytes = original?.highBytes
    }

    public static func project(usedBytes: Int64, remainingSeconds: [TransferDirection: Double],
                               observedMbps: [TransferDirection: Double]) -> Int64 {
        var extra = 0.0
        for (d, seconds) in remainingSeconds { extra += max(0, seconds) * (observedMbps[d] ?? 0) * 1_000_000 / 8 }
        return usedBytes + Int64(extra)
    }
}

/// Mobile-data safety limits for the stress test (all optional; nil = no limit).
///
/// * `warningBytes` — UI turns amber past this total.
/// * `hardCapBytes` — once reached, remaining throughput phases are skipped (the running transfer
///   is capped via `byteCap`); low-data diagnostics (latency, loss, DNS, protocols, route) still run.
/// * `downloadCapBytes` / `uploadCapBytes` — the same per direction.
public struct StressDataLimits: Codable, Sendable, Hashable {
    public var warningBytes: Int64?
    /// Second, stronger warning (amber → red) before the hard cap; nil before v2.2.1.
    public var softWarningBytes: Int64?
    public var hardCapBytes: Int64?
    public var downloadCapBytes: Int64?
    public var uploadCapBytes: Int64?
    /// The user explicitly chose "unlimited" (the only way a cellular run is uncapped).
    public var explicitlyUnlimited: Bool?
    /// How the limits were chosen: "userConfigured", "cellularDefault", "explicitUnlimited" or
    /// "unlimitedNonCellular"; nil before v2.2.1.
    public var policy: String?

    public init(warningBytes: Int64? = nil, softWarningBytes: Int64? = nil, hardCapBytes: Int64? = nil, downloadCapBytes: Int64? = nil,
                uploadCapBytes: Int64? = nil, explicitlyUnlimited: Bool? = nil, policy: String? = nil) {
        self.warningBytes = warningBytes
        self.softWarningBytes = softWarningBytes
        self.hardCapBytes = hardCapBytes
        self.downloadCapBytes = downloadCapBytes
        self.uploadCapBytes = uploadCapBytes
        self.explicitlyUnlimited = explicitlyUnlimited
        self.policy = policy
    }

    public static let unlimited = StressDataLimits()
    public static let gigabyte: Int64 = 1_000_000_000
    public static let megabyte: Int64 = 1_000_000
    public static let capPresetsGB: [Int] = [2, 5, 10, 20, 50]
    /// Hard-cap choices in MB (UI).
    public static let capPresetsMB: [Int] = [500, 1000, 1500, 2000, 5000, 10000, 20000, 50000]

    /// Default for cellular when nothing was configured: warning 500 MB, soft warning 750 MB,
    /// hard cap 1.5 GB (the 86 s v2.2.0 run used ≈ 1.02 GB).
    public static let cellularDefault = StressDataLimits.withHardCap(1_500 * megabyte, policy: "cellularDefault")

    /// Hard cap with warnings at ⅓ (warning) and ½ (soft warning) of it.
    public static func withHardCap(_ cap: Int64, downloadCap: Int64? = nil, uploadCap: Int64? = nil, policy: String = "userConfigured") -> StressDataLimits {
        StressDataLimits(warningBytes: cap / 3, softWarningBytes: cap / 2, hardCapBytes: cap,
                         downloadCapBytes: downloadCap, uploadCapBytes: uploadCap, explicitlyUnlimited: false, policy: policy)
    }

    /// Limits the runner enforces: on cellular, "no limits configured" becomes `cellularDefault`
    /// unless the user explicitly chose unlimited.
    public func effective(onCellular: Bool) -> StressDataLimits {
        if isLimited {
            var l = self
            if l.policy == nil { l.policy = "userConfigured" }
            return l
        }
        if explicitlyUnlimited == true {
            var l = self
            l.policy = "explicitUnlimited"
            return l
        }
        if onCellular { return .cellularDefault }
        var l = self
        l.policy = "unlimitedNonCellular"
        return l
    }

    /// Remaining bytes a transfer in `direction` may use; nil = unlimited, ≤ 0 = cap reached.
    public func remaining(_ direction: TransferDirection, down: Int64, up: Int64) -> Int64? {
        var caps: [Int64] = []
        if let h = hardCapBytes { caps.append(h - down - up) }
        if direction == .download, let d = downloadCapBytes { caps.append(d - down) }
        if direction == .upload, let u = uploadCapBytes { caps.append(u - up) }
        return caps.min()
    }

    public var isLimited: Bool { hardCapBytes != nil || downloadCapBytes != nil || uploadCapBytes != nil }
}

/// Extreme Stress Test plan. The user only picks the total duration; intensity never changes.
///
/// Rounds (repeat load to observe degradation, drift and scheduler changes):
///
///     T ≤ 180 s → 1 round · T ≤ 600 s → 2 rounds · otherwise 3 rounds
///
/// Fixed / floor-bounded phases (seconds):
///
///     healthCheck 4 · warmUp 3 · idle max(5, 5 % T) · loss max(10, 10 % T) · monitoring max(10, 7 % T)
///     dnsProtocols clamp(8 % T, 10, 25) · ipFamilies max(4, 3 % T) · routeMTU 15 (T < 180) or 30
///     per round: recovery max(4, 2 % T / R) · cross-server max(3, 3 % T / R)
///
/// Throughput: budget = max(T − fixed, 40 % T); per transfer (node × direction × round)
///
///     NDT7 nodes: min(max(6, budget / (2 × R × N)), 10)        (protocol limit)
///     HTTP nodes: max(6, (budget − NDT7 share) / (2 × R × N_http))
///
/// Streams are always 16 for HTTP nodes (NDT7 is single-stream by design); ICMP stress 50 pps,
/// control probes 5 pps.
public struct StressTestPlan: Codable, Sendable, Hashable {
    public var requestedSeconds: Double
    public var rounds: Int
    public var nodes: [StressNode]
    public var phases: [StressPlanPhase]
    public var streams: Int
    public var stressPacketsPerSecond: Double
    public var controlPacketsPerSecond: Double
    /// Seconds per HTTP transfer (one node, one direction, one round).
    public var transferSeconds: Double
    /// v3.0 stress parameters (nil in plans saved before v3.0).
    public var rampStages: [Int]?
    public var rampStageSeconds: Double?
    public var burstCycles: Int?
    public var burstLoadSeconds: Double?
    public var burstIdleSeconds: Double?

    public static let presets: [Double] = [60, 180, 300, 600, 900]
    public static let minimumSeconds: Double = 60
    public static let maximumSeconds: Double = 3600
    public static let ndt7MaxSeconds: Double = 10
    public static let maxStreams = 16

    /// v3.0: one standard throughput round; the time of former repeat rounds goes to the stress phases.
    public static func rounds(for seconds: Double) -> Int { 1 }

    /// Budget (seconds, T = requested, clamped to 60…3600):
    ///
    ///     fixed      healthCheck 4 · warmUp 3 · idle max(5, 4 % T)
    ///                standard HTTP transfer clamp(4 % T, 6, 15) per direction · NDT7 min(that, 10)
    ///                recovery (reference) max(3, 1.5 % T) · cross-server max(3, 2 % T)
    ///                dns/protocols clamp(5 % T, 8, 20) · ipFamilies max(4, 2 % T) · route/MTU 15 (T < 180) or 20
    ///                packet loss max(10, 5 % T) · monitoring max(8, 3 % T)
    ///     flexible   F = max(T₃₀₀ − fixed, Σ minimums), T₃₀₀ = min(T, 300); each phase = max(min, weight × F)
    ///                ramp 14 % (7 stages) · sustained ↓ 17 % · sustained ↑ 13 % · full duplex 14 %
    ///                burst 17 % (3 s load + 2 s idle cycles, 3…10) · multi-destination 7 %
    ///                short recoveries 6 % (3×) · final recovery 12 % (15…30 s)
    ///     T > 300    the extra time goes to sustained ↓ 30 % · sustained ↑ 25 % · full duplex 25 % · final recovery 20 %
    public static func make(totalSeconds: Double, nodes: [StressNode]) -> StressTestPlan {
        let t = min(max(totalSeconds, minimumSeconds), maximumSeconds)
        let throughputNodes = nodes.filter(\.isThroughputCapable)
        let httpNodes = throughputNodes.filter { $0.provider != .mlab }
        let transfer = min(15, max(6, 0.04 * t))
        let ndt7 = min(transfer, ndt7MaxSeconds)
        let idle = max(5, 0.04 * t)
        let recovery = max(3, 0.015 * t)
        let cross = max(3, 0.02 * t)
        let dnsProtocols = min(20, max(8, 0.05 * t))
        let ipFamilies = max(4, 0.02 * t)
        let route: Double = t < 180 ? 15 : 20
        let loss = max(10, 0.05 * t)
        let monitoring = max(8, 0.03 * t)
        let standard = throughputNodes.reduce(0.0) { $0 + 2 * ($1.provider == .mlab ? ndt7 : transfer) }
        let fixed = 4 + 3 + idle + standard + recovery + cross + dnsProtocols + ipFamilies + route + loss + monitoring

        let stages = StreamRampResult.defaultStages
        let hasHTTP = !httpNodes.isEmpty
        // name: (weight, minimum)
        let spec: [(StressPhaseKind, Double, Double)] = [
            (.streamRamp, 0.14, 2.0 * Double(stages.count)), (.sustainedDownload, 0.17, 10), (.sustainedUpload, 0.13, 10),
            (.fullDuplex, 0.14, 10), (.burst, 0.17, 15), (.multiDestination, 0.07, 8), (.shortRecovery, 0.06, 9), (.finalRecovery, 0.12, 15),
        ]
        let minimums = spec.reduce(0) { $0 + $1.2 }
        let flexible = max(min(t, 300) - fixed, minimums)
        var alloc: [StressPhaseKind: Double] = [:]
        for (kind, weight, minimum) in spec { alloc[kind] = max(minimum, weight * flexible) }
        let extra = max(0, t - max(300, fixed + minimums))
        alloc[.sustainedDownload, default: 0] += 0.30 * extra
        alloc[.sustainedUpload, default: 0] += 0.25 * extra
        alloc[.fullDuplex, default: 0] += 0.25 * extra
        alloc[.finalRecovery, default: 0] += 0.20 * extra
        alloc[.finalRecovery] = min(max(15, alloc[.finalRecovery]!), 30 + 0.20 * extra)
        let rampStage = alloc[.streamRamp]! / Double(stages.count)
        let cycles = Int(min(10, max(3, (alloc[.burst]! / 5).rounded(.down))))

        var phases: [StressPlanPhase] = [
            StressPlanPhase(kind: .healthCheck, seconds: 4),
            StressPlanPhase(kind: .warmUp, seconds: 3),
            StressPlanPhase(kind: .idleLatency, seconds: idle),
        ]
        for node in throughputNodes {
            let s = node.provider == .mlab ? ndt7 : transfer
            phases.append(StressPlanPhase(kind: .downloadStress, round: 1, nodeID: node.id, seconds: s))
            phases.append(StressPlanPhase(kind: .uploadStress, round: 1, nodeID: node.id, seconds: s))
        }
        phases.append(StressPlanPhase(kind: .postLoadRecovery, round: 1, seconds: recovery))
        phases.append(StressPlanPhase(kind: .crossServerValidation, round: 1, seconds: cross))
        phases += [
            StressPlanPhase(kind: .dnsProtocols, seconds: dnsProtocols),
            StressPlanPhase(kind: .ipFamilies, seconds: ipFamilies),
            StressPlanPhase(kind: .routeMTU, seconds: route),
        ]
        if hasHTTP {
            let shortRec = alloc[.shortRecovery]! / 3
            phases += [
                StressPlanPhase(kind: .streamRamp, nodeID: httpNodes[0].id, seconds: rampStage * Double(stages.count)),
                StressPlanPhase(kind: .sustainedDownload, nodeID: httpNodes[0].id, seconds: alloc[.sustainedDownload]!),
                StressPlanPhase(kind: .shortRecovery, round: 1, seconds: shortRec),
                StressPlanPhase(kind: .sustainedUpload, nodeID: httpNodes[0].id, seconds: alloc[.sustainedUpload]!),
                StressPlanPhase(kind: .shortRecovery, round: 2, seconds: shortRec),
                StressPlanPhase(kind: .fullDuplex, nodeID: httpNodes[0].id, seconds: alloc[.fullDuplex]!),
                StressPlanPhase(kind: .shortRecovery, round: 3, seconds: shortRec),
                StressPlanPhase(kind: .burst, nodeID: httpNodes[0].id, seconds: Double(cycles) * 5),
            ]
            if throughputNodes.count >= 2 { phases.append(StressPlanPhase(kind: .multiDestination, seconds: alloc[.multiDestination]!)) }
        }
        phases += [
            StressPlanPhase(kind: .packetLossStress, seconds: loss),
            StressPlanPhase(kind: .monitoring, seconds: monitoring),
            StressPlanPhase(kind: .finalRecovery, seconds: alloc[.finalRecovery]!),
        ]
        var plan = StressTestPlan(requestedSeconds: t, rounds: 1, nodes: nodes, phases: phases, streams: maxStreams,
                                  stressPacketsPerSecond: 50, controlPacketsPerSecond: 5, transferSeconds: transfer)
        plan.rampStages = stages
        plan.rampStageSeconds = rampStage
        plan.burstCycles = cycles
        plan.burstLoadSeconds = 3
        plan.burstIdleSeconds = 2
        return plan
    }

    public var estimatedSeconds: Double { phases.reduce(0) { $0 + $1.seconds } }
    public var throughputNodes: [StressNode] { nodes.filter(\.isThroughputCapable) }
    public var latencyOnlyNodes: [StressNode] { nodes.filter { !$0.isThroughputCapable } }

    /// Seconds per phase kind, in execution order.
    public var totalsByKind: [(kind: StressPhaseKind, seconds: Double)] {
        var order: [StressPhaseKind] = []
        var sums: [StressPhaseKind: Double] = [:]
        for p in phases {
            if sums[p.kind] == nil { order.append(p.kind) }
            sums[p.kind, default: 0] += p.seconds
        }
        return order.map { ($0, sums[$0]!) }
    }

    public func phases(round: Int) -> [StressPlanPhase] { phases.filter { $0.round == round } }

    /// Seconds of the non-throughput phases (health check, idle, loss, monitoring, DNS, route…).
    public var diagnosticSeconds: Double {
        phases.filter { !$0.kind.isLoadPhase }.reduce(0) { $0 + $1.seconds }
    }

    /// Why the planned duration differs from the configured one:
    ///
    ///     none                              |planned − configured| < 1 s
    ///     requestedBelowMinimum             configured < 60 s (clamped)
    ///     minimumRequiredDiagnosticPhases   diagnostic floors > 60 % of T, throughput kept at 40 % of T
    ///     minimumTransferSeconds            6 s per-transfer floor across nodes × directions × rounds
    ///     ndt7ProtocolCap                   planned shorter: NDT7 transfers capped at 10 s
    public func durationAdjustmentReason(configuredSeconds: Double) -> String {
        let diff = estimatedSeconds - configuredSeconds
        if abs(diff) < 1 { return "none" }
        if configuredSeconds < Self.minimumSeconds { return "requestedBelowMinimum" }
        if diff < 0 { return "ndt7ProtocolCap" }
        return diagnosticSeconds > 0.6 * requestedSeconds ? "minimumRequiredDiagnosticPhases" : "minimumTransferSeconds"
    }

    /// Expected bytes if the link sustains the given rates for every transfer phase.
    /// Seconds of load per direction over every load phase (standard + stress).
    public var loadSeconds: (download: Double, upload: Double) {
        phases.reduce((0.0, 0.0)) { ($0.0 + $1.seconds * $1.kind.loadShare.download, $0.1 + $1.seconds * $1.kind.loadShare.upload) }
    }

    public func trafficEstimate(downloadMbps: Double, uploadMbps: Double, networkClass: NetworkClass? = nil) -> TrafficEstimate {
        let (dl, ul) = loadSeconds
        var e = TrafficEstimate(downloadBytes: Int64(dl * downloadMbps * 1_000_000 / 8),
                                uploadBytes: Int64(ul * uploadMbps * 1_000_000 / 8),
                                assumedDownloadMbps: downloadMbps, assumedUploadMbps: uploadMbps)
        if let networkClass {
            let c = Self.ceilingMbps(for: networkClass)
            let cd = max(c.download, downloadMbps), cu = max(c.upload, uploadMbps)
            e.ceilingDownloadMbps = cd
            e.ceilingUploadMbps = cu
            e.ceilingBytes = Int64((dl * cd + ul * cu) * 1_000_000 / 8)
        }
        return e
    }

    /// Fast-link rates per network type for the upper end of the range (high-band 5G / Wi-Fi 6/7
    /// can far exceed the conservative point estimate).
    public static func ceilingMbps(for networkClass: NetworkClass) -> (download: Double, upload: Double) {
        switch networkClass {
        case .nr: (1600, 250)
        case .wifi, .wired: (1200, 600)
        case .lte: (350, 100)
        case .cellularOther, .unknown: (1200, 250)
        }
    }

    /// Rates for the traffic estimate: median of the last (≤ 10) results measured on the same
    /// network class, else `defaultAssumedMbps`. `fromHistory` says which one was used.
    public static func assumedMbps(history: [TestResult], networkClass: NetworkClass) -> (download: Double, upload: Double, fromHistory: Bool) {
        let same = history.filter { NetworkClass(snapshot: $0.network) == networkClass && !$0.wasCancelled }
            .sorted { $0.date > $1.date }.prefix(10)
        let dl = Descriptive.median(same.compactMap { $0.metrics.downloadMbps })
        let ul = Descriptive.median(same.compactMap { $0.metrics.uploadMbps })
        let d = defaultAssumedMbps(for: networkClass)
        return (dl ?? d.download, ul ?? d.upload, dl != nil || ul != nil)
    }

    /// Rates to assume when no earlier result on this network class exists.
    public static func defaultAssumedMbps(for networkClass: NetworkClass) -> (download: Double, upload: Double) {
        switch networkClass {
        case .wifi, .wired: (300, 100)
        case .nr: (400, 60)
        case .lte: (80, 20)
        case .cellularOther, .unknown: (50, 10)
        }
    }

    /// Warnings shown before start. Constrained / expensive paths only add warnings — the plan
    /// and its intensity never change.
    public static func warnings(for network: NetworkSnapshot) -> [String] {
        var out: [String] = []
        if network.isConstrained { out.append("目前開啟「低數據模式」。壓力測試仍會以最大強度執行，不會降低流量。") }
        if network.isExpensive { out.append("目前為計量網路（行動網路 / 個人熱點），可能消耗大量行動數據。") }
        if network.primaryInterface == .cellular {
            out.append("若正在漫遊，行動數據費用可能很高；iOS 不提供漫遊狀態，請自行確認。")
        }
        if network.vpn.state == .detected { out.append("偵測到 VPN：結果代表 VPN 通道，而非原生網路。") }
        return out
    }

    public static let confirmationWarning = "極限壓力測試會長時間使用最大可用頻寬，可能消耗大量行動數據，並增加耗電與裝置溫度。"
}
