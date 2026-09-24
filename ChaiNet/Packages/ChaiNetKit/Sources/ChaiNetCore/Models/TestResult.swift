import Foundation

public enum TestKind: String, Codable, Sendable, Hashable, CaseIterable {
    case fullSpeedTest
    case gaming
    case voice
    case streaming
    case obsUpload
    case dnsBenchmark
    case protocolProbe
    case traceroute
    case mtu
    case monitoring
    case interfaceCompare
    case extremeFullTest
    case extremeStressTest

    public var displayName: String {
        switch self {
        case .fullSpeedTest: "完整測速"
        case .gaming: "遊戲品質"
        case .voice: "語音品質"
        case .streaming: "串流品質"
        case .obsUpload: "OBS 上傳"
        case .dnsBenchmark: "DNS 測試"
        case .protocolProbe: "協定分析"
        case .traceroute: "路由追蹤"
        case .mtu: "MTU 測試"
        case .monitoring: "連續監測"
        case .interfaceCompare: "Wi-Fi / 行動網路比較"
        case .extremeFullTest: "完整測試（極限）"
        case .extremeStressTest: "極限壓力測試"
        }
    }
}

/// Optional, local-only location attached to a result (user opt-in; never uploaded).
public struct GeoPoint: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// Continuous-monitoring session result.
public struct MonitoringResult: Codable, Sendable, Hashable {
    public var target: String
    public var intervalSeconds: Double
    public var samples: [LatencySample]
    public var statistics: LatencyStatistics
    public var spikes: [LatencySpikeEvent]
    public var drops: [NetworkDropEvent]
    public var pathChanges: [PathChangeEvent]

    public init(target: String, intervalSeconds: Double, samples: [LatencySample], statistics: LatencyStatistics,
                spikes: [LatencySpikeEvent], drops: [NetworkDropEvent], pathChanges: [PathChangeEvent]) {
        self.target = target
        self.intervalSeconds = intervalSeconds
        self.samples = samples
        self.statistics = statistics
        self.spikes = spikes
        self.drops = drops
        self.pathChanges = pathChanges
    }
}

public struct PathChangeEvent: Codable, Sendable, Hashable {
    public var offset: Double
    public var interface: InterfaceKind
    public var status: PathStatus

    public init(offset: Double, interface: InterfaceKind, status: PathStatus) {
        self.offset = offset
        self.interface = interface
        self.status = status
    }
}

/// Per-interface result used by the Wi-Fi vs Cellular comparison.
public struct InterfaceProbeResult: Codable, Sendable, Hashable, Identifiable {
    public var interface: InterfaceKind
    public var tcpConnect: LatencyStatistics?
    public var error: String?
    public var id: InterfaceKind { interface }

    public init(interface: InterfaceKind, tcpConnect: LatencyStatistics?, error: String?) {
        self.interface = interface
        self.tcpConnect = tcpConnect
        self.error = error
    }
}

/// The unit that is persisted, exported and shared. Only the parts relevant to `kind` are set.
public struct TestResult: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var kind: TestKind
    public var server: ServerDescriptor?
    public var serverInfo: ServerInfo?
    public var network: NetworkSnapshot
    public var location: GeoPoint?

    public var download: SpeedResult?
    public var upload: SpeedResult?
    public var idleLatency: LatencyStatistics?
    public var idleSamples: [LatencySample]?
    public var downloadLoadedLatency: LatencyStatistics?
    public var uploadLoadedLatency: LatencyStatistics?
    /// Dedicated loss test (UDP echo or ICMP) — TCP-based probes can't observe loss.
    public var packetLoss: LatencyStatistics?
    public var packetLossMethod: String?
    public var bufferbloat: BufferbloatResult?

    public var dns: DNSBenchmarkResult?
    public var protocolProbe: ProtocolProbeResult?
    public var traceroute: TracerouteResult?
    public var mtu: MTUResult?
    public var gaming: GamingQualityResult?
    public var voice: VoiceQualityResult?
    public var streaming: StreamingQualityResult?
    public var obs: OBSSuitabilityResult?
    public var monitoring: MonitoringResult?
    public var interfaceCompare: [InterfaceProbeResult]?
    /// Automatic cross-validation against independent endpoints (triggered when the primary
    /// server looks abnormal, or on demand).
    public var crossValidation: [EndpointCheck]?
    /// Same target measured over IPv4 and IPv6 separately.
    public var ipFamilyComparison: IPFamilyComparisonResult?
    /// Health of the test server at test time (`/health`).
    public var serverHealth: ServerHealth?
    /// IP family the test was forced to (session tests E/F).
    public var ipFamilyPreference: IPFamilyPreference
    /// The same server-dependent measurements repeated on additional servers (multi-server test).
    public var serverRuns: [ServerRun]?
    /// Every raw probe behind the loaded-latency and packet-loss statistics (kept for export).
    public var downloadLoadedSamples: [LatencySample]?
    public var uploadLoadedSamples: [LatencySample]?
    public var packetLossSamples: [LatencySample]?
    /// Time plan of an extreme full test.
    public var fullTestPlan: FullTestPlan?
    /// Extreme Stress Test: per-node, per-round results, loss confirmation, traffic totals.
    public var stress: StressSummary?

    public var scores: QualityScores
    public var findings: [DiagnosticFinding]
    public var wasCancelled: Bool
    public var notes: [String]

    public init(id: UUID = UUID(), date: Date = Date(), kind: TestKind, network: NetworkSnapshot) {
        self.id = id
        self.date = date
        self.kind = kind
        self.network = network
        self.scores = .empty
        self.findings = []
        self.wasCancelled = false
        self.notes = []
        self.ipFamilyPreference = .automatic
    }

    /// Whole-series spike analysis of the monitoring samples. The pre-load idle baseline is used
    /// only when it was measured with the same probe and target (stress test reference path);
    /// otherwise the series is its own baseline (never compare different probe methods).
    public var monitoringSpikeSummary: SpikeSummary? {
        guard let monitoring else { return nil }
        let sameProbe = kind == .extremeStressTest
        return SpikeAnalyzer.analyze(monitoring.samples, baseline: sameProbe ? idleLatency : nil)
    }

    /// Flattens the result for the Score / Diagnostics engines.
    public var metrics: MetricSnapshot {
        var m = MetricSnapshot()
        // Invalid transfers (error page, tiny body, rate limit…) are never measurements; artifact-
        // contaminated short-window statistics (stability, peak) are unavailable, not bad.
        let dl = [download, streaming?.download].compactMap { $0 }.first { $0.isValid }
        let ul = [upload, obs?.upload].compactMap { $0 }.first { $0.isValid }
        m.downloadMbps = dl?.summary.averageMbps
        m.downloadPeakMbps = dl?.summary.reliablePeakMbps
        m.uploadMbps = ul?.summary.averageMbps
        m.downloadStability = dl?.summary.reliableStabilityScore
        m.uploadStability = ul?.summary.reliableStabilityScore

        let latency = idleLatency ?? gaming?.idle ?? voice?.latency ?? monitoring?.statistics
        m.idleLatencyMs = latency?.rtt?.median
        m.idleLatencyP95Ms = latency?.rtt?.p95
        m.jitterMs = latency?.rtt?.jitter

        // Prefer the dedicated loss measurement; fall back to what the latency probe saw.
        let loss = packetLoss?.loss ?? gaming?.idle.loss ?? voice?.latency.loss ?? monitoring?.statistics.loss ?? latency?.loss
        if let loss, loss.sent > 0 {
            m.lossPercent = loss.lossPercent
            m.lossPattern = loss.pattern
            m.burstLossPercent = loss.burstLossPercent
        }
        m.downloadBloatMs = bufferbloat?.downloadIncreaseMs
        m.uploadBloatMs = bufferbloat?.uploadIncreaseMs

        if let dns {
            let system = dns.resolvers.first { $0.resolver.transport == .system }?.statistics.rtt
            m.systemDNSMs = system?.median
            m.systemDNSP95Ms = system?.p95
            if let best = dns.ranked.first(where: { $0.resolver.transport != .system && $0.statistics.rtt != nil }) {
                m.bestDNSMs = best.statistics.rtt?.median
                m.bestDNSName = best.resolver.name
            }
        }
        if network.status == .satisfied {
            m.supportsIPv4 = network.supportsIPv4
            m.supportsIPv6 = network.supportsIPv6
            m.isExpensive = network.isExpensive
            m.isConstrained = network.isConstrained
            m.interface = network.primaryInterface
        }
        m.vpnDetected = network.vpn.state == .unknown ? nil : network.vpn.state == .detected
        if let probe = protocolProbe {
            m.negotiatedHTTP = probe.http?.negotiatedProtocol
            m.http3Supported = probe.http3Negotiated
            m.quicReachable = probe.quicReachable
            m.http3ProbeHost = probe.host
            if let attempt = probe.http3Attempt {
                m.strictHTTP3EndpointsAttempted = 1
                m.strictHTTP3EndpointsFailed = probe.http3Negotiated ? 0 : 1
                if !probe.http3Negotiated { m.http3FallbackProtocol = attempt.negotiatedProtocol }
            }
            m.tlsHandshakeMs = probe.http?.tlsMs
            m.ttfbMs = probe.http?.ttfbMs
        }
        m.pathMTU = mtu?.pathMTU
        if let stress {
            // Stress: cross-provider medians of valid transfers, reliable stability only, confirmed
            // (multi-probe) loss and loaded latency from transfers that really loaded the link.
            m.downloadMbps = stress.headlineMbps(.download)
            m.uploadMbps = stress.headlineMbps(.upload)
            m.downloadPeakMbps = stress.downloadAggregate?.maxMbps
            m.downloadStability = stress.stability(.download)
            m.uploadStability = stress.stability(.upload)
            if let v = stress.lossConfirmation.confirmedLossPercent { m.lossPercent = v }
            m.downloadBloatMs = stress.loadedLatencyIncreaseMs(.download)
            m.uploadBloatMs = stress.loadedLatencyIncreaseMs(.upload)
        }
        if let monitoring {
            m.spikeCount = max(monitoring.spikes.count, monitoringSpikeSummary?.count ?? 0)
            m.dropCount = monitoring.drops.count
            m.sampleDurationSeconds = monitoring.samples.last?.offset
        } else if let gaming {
            m.spikeCount = gaming.spikes.count
        }
        return m
    }

    /// Recomputes scores and findings from the current data.
    public mutating func evaluate(scoreEngine: any ScoreEngineProtocol = ScoreEngine(),
                                  diagnostics: any DiagnosticsEngineProtocol = DiagnosticsEngine()) {
        let m = metrics
        scores = scoreEngine.scores(for: m)
        findings = diagnostics.diagnose(m)
    }
}

public enum IPFamilyPreference: String, Codable, Sendable, Hashable, CaseIterable {
    case automatic
    case ipv4Only
    case ipv6Only

    public var displayName: String {
        switch self {
        case .automatic: "自動（系統選擇）"
        case .ipv4Only: "僅 IPv4"
        case .ipv6Only: "僅 IPv6"
        }
    }
}

public enum EndpointProbeMethod: String, Codable, Sendable, Hashable {
    case tcpConnect, udpEcho, httpPing, icmpEcho, quicHandshake
}

/// One independent endpoint measured during cross-validation.
public struct EndpointCheck: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var host: String
    /// Region / operator label (e.g. "Anycast", "Tokyo").
    public var region: String
    public var method: EndpointProbeMethod
    public var statistics: LatencyStatistics?
    public var error: String?
    /// True for the server used by the main test.
    public var isPrimary: Bool

    public init(id: String, name: String, host: String, region: String, method: EndpointProbeMethod,
                statistics: LatencyStatistics?, error: String?, isPrimary: Bool) {
        self.id = id
        self.name = name
        self.host = host
        self.region = region
        self.method = method
        self.statistics = statistics
        self.error = error
        self.isPrimary = isPrimary
    }
}

public struct IPFamilyComparisonResult: Codable, Sendable, Hashable {
    public var target: String
    public var method: EndpointProbeMethod
    public var ipv4: LatencyStatistics?
    public var ipv6: LatencyStatistics?
    public var ipv4Error: String?
    public var ipv6Error: String?

    public init(target: String, method: EndpointProbeMethod, ipv4: LatencyStatistics?, ipv6: LatencyStatistics?, ipv4Error: String?, ipv6Error: String?) {
        self.target = target
        self.method = method
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.ipv4Error = ipv4Error
        self.ipv6Error = ipv6Error
    }
}

public struct ServerHealth: Codable, Sendable, Hashable {
    public var reachable: Bool
    public var healthy: Bool
    public var responseMs: Double?
    public var activeSessions: Int?
    public var detail: String?

    public init(reachable: Bool, healthy: Bool, responseMs: Double?, activeSessions: Int?, detail: String?) {
        self.reachable = reachable
        self.healthy = healthy
        self.responseMs = responseMs
        self.activeSessions = activeSessions
        self.detail = detail
    }
}

/// Measurements of one additional server in a multi-server test.
public struct ServerRun: Codable, Sendable, Hashable, Identifiable {
    public var server: ServerDescriptor
    public var idleLatency: LatencyStatistics?
    public var packetLoss: LatencyStatistics?
    public var packetLossMethod: String?
    public var download: SpeedResult?
    public var upload: SpeedResult?
    public var error: String?
    public var id: String { server.id }

    public init(server: ServerDescriptor, idleLatency: LatencyStatistics? = nil, packetLoss: LatencyStatistics? = nil,
                packetLossMethod: String? = nil, download: SpeedResult? = nil, upload: SpeedResult? = nil, error: String? = nil) {
        self.server = server
        self.idleLatency = idleLatency
        self.packetLoss = packetLoss
        self.packetLossMethod = packetLossMethod
        self.download = download
        self.upload = upload
        self.error = error
    }
}
