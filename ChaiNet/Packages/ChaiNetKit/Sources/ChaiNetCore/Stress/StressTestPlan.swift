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
        case .extendedMonitoring: "延長監測（回收未用時間）"
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
    public var totalBytes: Int64 { downloadBytes + uploadBytes }
    /// Range shown to the user: real rates vary, so ±30 % around the point estimate.
    public var lowBytes: Int64 { Int64(Double(totalBytes) * 0.7) }
    public var highBytes: Int64 { Int64(Double(totalBytes) * 1.3) }
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

    public static let presets: [Double] = [60, 180, 300, 600, 900]
    public static let minimumSeconds: Double = 60
    public static let maximumSeconds: Double = 3600
    public static let ndt7MaxSeconds: Double = 10
    public static let maxStreams = 16

    public static func rounds(for seconds: Double) -> Int { seconds <= 180 ? 1 : (seconds <= 600 ? 2 : 3) }

    public static func make(totalSeconds: Double, nodes: [StressNode]) -> StressTestPlan {
        let t = min(max(totalSeconds, minimumSeconds), maximumSeconds)
        let r = rounds(for: t)
        let throughputNodes = nodes.filter(\.isThroughputCapable)
        let n = Double(max(1, throughputNodes.count))
        let rd = Double(r)
        let idle = max(5, 0.05 * t)
        let loss = max(10, 0.10 * t)
        let monitoring = max(10, 0.07 * t)
        let dnsProtocols = min(25, max(10, 0.08 * t))
        let ipFamilies = max(4, 0.03 * t)
        let route: Double = t < 180 ? 15 : 30
        let recovery = max(4, 0.02 * t / rd)
        let cross = max(3, 0.03 * t / rd)
        let fixed = 4 + 3 + idle + loss + monitoring + dnsProtocols + ipFamilies + route + rd * (recovery + cross)
        let budget = max(t - fixed, 0.4 * t)
        // NDT7 transfers are capped by the protocol; their unused share goes to the HTTP nodes.
        let mlabCount = Double(throughputNodes.filter { $0.provider == .mlab }.count)
        let httpCount = n - mlabCount
        let even = budget / (2 * rd * n)
        let mlabSeconds = min(max(6, even), ndt7MaxSeconds)
        let transfer = httpCount > 0 ? max(6, (budget - 2 * rd * mlabCount * mlabSeconds) / (2 * rd * httpCount)) : max(6, even)

        var phases: [StressPlanPhase] = [
            StressPlanPhase(kind: .healthCheck, seconds: 4),
            StressPlanPhase(kind: .warmUp, seconds: 3),
            StressPlanPhase(kind: .idleLatency, seconds: idle),
        ]
        for round in 1...r {
            for node in throughputNodes {
                let s = node.provider == .mlab ? min(transfer, ndt7MaxSeconds) : transfer
                phases.append(StressPlanPhase(kind: .downloadStress, round: round, nodeID: node.id, seconds: s))
                phases.append(StressPlanPhase(kind: .uploadStress, round: round, nodeID: node.id, seconds: s))
            }
            phases.append(StressPlanPhase(kind: .postLoadRecovery, round: round, seconds: recovery))
            phases.append(StressPlanPhase(kind: .crossServerValidation, round: round, seconds: cross))
        }
        phases += [
            StressPlanPhase(kind: .packetLossStress, seconds: loss),
            StressPlanPhase(kind: .monitoring, seconds: monitoring),
            StressPlanPhase(kind: .dnsProtocols, seconds: dnsProtocols),
            StressPlanPhase(kind: .ipFamilies, seconds: ipFamilies),
            StressPlanPhase(kind: .routeMTU, seconds: route),
        ]
        return StressTestPlan(requestedSeconds: t, rounds: r, nodes: nodes, phases: phases, streams: maxStreams,
                              stressPacketsPerSecond: 50, controlPacketsPerSecond: 5, transferSeconds: transfer)
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
        phases.filter { $0.kind != .downloadStress && $0.kind != .uploadStress }.reduce(0) { $0 + $1.seconds }
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
    public func trafficEstimate(downloadMbps: Double, uploadMbps: Double) -> TrafficEstimate {
        let dl = phases.filter { $0.kind == .downloadStress }.reduce(0) { $0 + $1.seconds }
        let ul = phases.filter { $0.kind == .uploadStress }.reduce(0) { $0 + $1.seconds }
        return TrafficEstimate(downloadBytes: Int64(dl * downloadMbps * 1_000_000 / 8),
                               uploadBytes: Int64(ul * uploadMbps * 1_000_000 / 8),
                               assumedDownloadMbps: downloadMbps, assumedUploadMbps: uploadMbps)
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
