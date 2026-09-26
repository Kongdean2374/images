import Foundation

/// Network layer a finding or hypothesis belongs to (from the device outwards).
public enum NetworkLayer: String, Codable, Sendable, Hashable, CaseIterable {
    case device        // iPhone, iOS, VPN client, app environment
    case localNetwork  // Wi-Fi radio, router, LAN
    case accessLink    // last mile: cable/fibre/DSL line, cellular radio
    case carrierCore   // ISP / carrier core network, SIM / APN / modem path
    case routing       // transit and peering between ISP and destination
    case server        // test server / endpoint
    case application   // DNS, TLS, HTTP, QUIC
    case pathQueueing  // queueing somewhere on the access / network path; exact hop unknown

    public var displayName: String {
        switch self {
        case .device: "裝置 / 系統"
        case .localNetwork: "區域網路 / Wi-Fi"
        case .accessLink: "接取網路 / 無線電"
        case .carrierCore: "ISP / 電信核心網路"
        case .routing: "路由 / 國際互連"
        case .server: "伺服器"
        case .application: "應用協定（DNS / TLS / HTTP）"
        case .pathQueueing: "存取 / 網路路徑佇列（實際位置未知）"
        }
    }
}

/// Which kind of measurement an evidence item comes from. Hypotheses declare the dimensions
/// they need; when a dimension was never measured the hypothesis is reported as
/// "insufficient evidence" instead of being guessed.
public enum EvidenceDimension: String, Codable, Sendable, Hashable, CaseIterable {
    case throughput
    case latency
    case loss
    case bufferbloat
    case dns
    case protocols
    case mtu
    case crossServer
    case ipFamily
    case interfaceCompare
    case radioCompare
    case baseline
    case stabilityMonitoring
    case environment
    case route

    public var displayName: String {
        switch self {
        case .throughput: "頻寬"
        case .latency: "延遲"
        case .loss: "封包遺失"
        case .bufferbloat: "負載延遲"
        case .dns: "DNS"
        case .protocols: "TCP / TLS / HTTP / QUIC"
        case .mtu: "MTU"
        case .crossServer: "多伺服器交叉驗證"
        case .ipFamily: "IPv4 / IPv6 比較"
        case .interfaceCompare: "Wi-Fi / 行動網路比較"
        case .radioCompare: "LTE / 5G 比較"
        case .baseline: "歷史基準"
        case .stabilityMonitoring: "連續監測"
        case .environment: "網路環境"
        case .route: "路由追蹤"
        }
    }
}

/// Every observation the analyzer can make. Codes are facts ("upload < 3 Mbps"), never
/// conclusions; conclusions are hypotheses.
public enum EvidenceCode: String, Codable, Sendable, Hashable, CaseIterable {
    // Throughput
    case downloadHigh, downloadNormal, downloadLow
    case uploadVeryLow, uploadLow, uploadNormal
    case asymmetricRatio
    case downloadUnstable, downloadStable, uploadUnstable, uploadStable
    // Latency / loss
    case idleLatencyLow, idleLatencyHigh
    case jitterHigh, jitterLow
    case lossNone, lossHigh, lossSevere, lossBursty, lossRandom
    /// High-rate ICMP stress probe lost packets while low-rate / other probes did not.
    case possibleICMPRateLimiting
    /// Loss seen only toward specific endpoint(s) while independent controls were clean.
    case endpointSpecificLossObserved
    /// Independent low-rate controls clean: no evidence of general loss (scoped replacement for lossNone).
    case noConfirmedGeneralLoss
    /// The endpoint(s) with loss also answer clearly slower than independent peers (same method).
    case endpointLatencyElevatedVsPeers
    /// One independent validation endpoint (not a speed-test server) behaves differently from its
    /// peers in latency-probe results only (ICMP / TCP). Scoped to that endpoint address.
    case endpointSpecificBehaviorObserved
    // v3.0 stress phases
    case saturationReached, streamScalingPlateau, sustainedThroughputDegradation, fullDuplexInterference
    case burstRecoverySlow, burstTriggeredLoss, multiDestinationHigherAggregate, postLoadRecoveryIncomplete
    case thermalStateChangedDuringLoad, loadCorrelatedLatencyInflation, loadCorrelatedLoss
    case latencySpikesFrequent
    // Bufferbloat
    case downloadBufferbloat, uploadBufferbloat, noBufferbloat
    /// Latency stayed elevated after the load stopped.
    case slowPostLoadRecovery
    /// Measured condition: loaded − idle latency ≥ 30 ms on a valid load (cause / location separate).
    case loadedLatencyInflationObserved
    /// Loaded latency rose, but idle and loaded were not measured comparably (different target /
    /// method, or a loaded-server target): indicative only (comparisonQuality=limited).
    case loadedLatencyRiseLimitedComparison
    // Application / protocol
    case dnsSlow, dnsFailures, dnsHealthy
    /// Median fine but P95 ≥ 200 ms and ≥ 3 × median (occasional very slow lookups).
    case dnsHighTailLatency
    /// Scoped DNS facts: the *system* resolver's median is fine (says nothing about its tail or
    /// other resolvers); tail latency seen on the system resolver; an alternate IPv6 resolver degraded.
    case systemDNSHealthy, dnsHighTailLatencyObserved, alternateIPv6ResolverDegraded
    /// One domain slow on several resolvers (cold authoritative lookup), not a resolver problem.
    case dnsDomainSpecificOutlier
    /// Every resolver of one transport (UDP / DoH) degraded while the others were fine.
    case dnsTransportSpecificIssue
    case tcpConnectSlow, tlsSlow, ttfbSlow
    case http3Negotiated, quicBlocked, quicEndpointFailure, quicImplementationFailure
    /// A QUIC handshake succeeded (UDP 443 reachable) — says nothing about HTTP/3 negotiation.
    case quicReachable
    /// QUIC handshake failed to a specific endpoint while other endpoints succeeded.
    case endpointQuicHandshakeFailed
    /// An HTTP/3-capable request fell back to TCP (HTTP/1.1 or HTTP/2) — inconclusive for HTTP/3.
    case http3FallbackObserved
    case mtuReduced, mtuNormal
    /// Path MTU observed on the tested path only (replaces the over-general `mtuNormal`).
    case pathMTUObserved
    // Environment
    case onWiFi, onCellular, on5G, onLTE, noCellularTests, no5GTests
    case vpnActive, vpnInactive
    case lowDataMode, notConstrained
    case pathChanged, connectionDrops, noDropsObserved
    case serverUnhealthy, serverHealthy
    case cellularRadioMetricsUnavailable
    // Cross-server
    case singleServerAnomalous, multipleServersAnomalous, allServersAnomalous, allServersNormal
    case regionSpecificAnomaly
    case serverThroughputOutlierLow, crossServerConsistentThroughput, higherLatencyRelativeToPeers
    case largeCrossProviderThroughputVariance, crossProviderThroughputConsistent
    /// Every node answered its pre-test health check (says nothing about throughput).
    case allServerHealthChecksPassed
    /// Nodes measured with non-equivalent methods (provider / protocol / streams): only a range.
    case crossProviderObservedRange, methodDependentThroughputDifference
    /// A throughput transfer to a server returned an invalid response (error page, tiny body, 429…) even after retry.
    case serverTransferInvalid
    // Route
    case routeLatencyStep, intermediateHopICMPDeprioritized
    // Sustained load
    case throughputDegradationUnderLoad
    // IP family
    case ipv6DegradedOnly, ipv4DegradedOnly, ipFamiliesEquivalent, ipv6Unavailable
    // Interfaces / radio
    case wifiNormalCellularDegraded, cellularNormalWifiDegraded
    case lteNormalNRDegraded, nrNormalLTEDegraded
    case allCellularDegradedWifiNormal
    case allInterfacesDegraded, allInterfacesNormal
    case interfaceProbeUnavailable
    // Baseline
    case deviatesFromBaseline, matchesBaseline, noBaseline

    public var dimension: EvidenceDimension {
        switch self {
        case .downloadHigh, .downloadNormal, .downloadLow, .uploadVeryLow, .uploadLow, .uploadNormal, .asymmetricRatio,
             .downloadUnstable, .downloadStable, .uploadUnstable, .uploadStable, .throughputDegradationUnderLoad,
             .saturationReached, .streamScalingPlateau, .sustainedThroughputDegradation, .fullDuplexInterference:
            .throughput
        case .burstRecoverySlow, .postLoadRecoveryIncomplete, .loadCorrelatedLatencyInflation:
            .bufferbloat
        case .burstTriggeredLoss, .loadCorrelatedLoss:
            .loss
        case .multiDestinationHigherAggregate:
            .crossServer
        case .thermalStateChangedDuringLoad:
            .environment
        case .idleLatencyLow, .idleLatencyHigh, .jitterHigh, .jitterLow, .latencySpikesFrequent:
            .latency
        case .lossNone, .lossHigh, .lossSevere, .lossBursty, .lossRandom, .possibleICMPRateLimiting, .endpointSpecificLossObserved, .noConfirmedGeneralLoss:
            .loss
        case .downloadBufferbloat, .uploadBufferbloat, .noBufferbloat, .slowPostLoadRecovery, .loadedLatencyInflationObserved,
             .loadedLatencyRiseLimitedComparison:
            .bufferbloat
        case .dnsSlow, .dnsFailures, .dnsHealthy, .dnsHighTailLatency, .systemDNSHealthy, .dnsHighTailLatencyObserved,
             .alternateIPv6ResolverDegraded, .dnsDomainSpecificOutlier, .dnsTransportSpecificIssue:
            .dns
        case .tcpConnectSlow, .tlsSlow, .ttfbSlow, .http3Negotiated, .quicBlocked, .quicEndpointFailure, .quicImplementationFailure,
             .quicReachable, .endpointQuicHandshakeFailed, .http3FallbackObserved:
            .protocols
        case .routeLatencyStep, .intermediateHopICMPDeprioritized:
            .route
        case .mtuReduced, .mtuNormal, .pathMTUObserved:
            .mtu
        case .onWiFi, .onCellular, .on5G, .onLTE, .noCellularTests, .no5GTests, .vpnActive, .vpnInactive, .lowDataMode,
             .notConstrained, .serverUnhealthy, .serverHealthy, .cellularRadioMetricsUnavailable:
            .environment
        case .pathChanged, .connectionDrops, .noDropsObserved:
            .stabilityMonitoring
        case .singleServerAnomalous, .multipleServersAnomalous, .allServersAnomalous, .allServersNormal, .regionSpecificAnomaly,
             .serverThroughputOutlierLow, .crossServerConsistentThroughput, .higherLatencyRelativeToPeers,
             .largeCrossProviderThroughputVariance, .crossProviderThroughputConsistent, .allServerHealthChecksPassed, .serverTransferInvalid,
             .crossProviderObservedRange, .methodDependentThroughputDifference, .endpointLatencyElevatedVsPeers, .endpointSpecificBehaviorObserved:
            .crossServer
        case .ipv6DegradedOnly, .ipv4DegradedOnly, .ipFamiliesEquivalent, .ipv6Unavailable:
            .ipFamily
        case .wifiNormalCellularDegraded, .cellularNormalWifiDegraded, .allCellularDegradedWifiNormal, .allInterfacesDegraded,
             .allInterfacesNormal, .interfaceProbeUnavailable:
            .interfaceCompare
        case .lteNormalNRDegraded, .nrNormalLTEDegraded:
            .radioCompare
        case .deviatesFromBaseline, .matchesBaseline, .noBaseline:
            .baseline
        }
    }
}

/// How an evidence item was obtained.
public enum EvidenceKind: String, Codable, Sendable, Hashable {
    /// Directly measured in a test (confirmed observation).
    case measured
    /// Derived by comparing several measurements (cross-test, baseline).
    case derived
    /// Heuristic inference (e.g. VPN detection has no public iOS API).
    case heuristic
    /// A test that was *not* run / a value the platform does not expose.
    case notTested

    public var displayName: String {
        switch self {
        case .measured: "實測"
        case .derived: "比較推導"
        case .heuristic: "啟發式"
        case .notTested: "未測試 / 無法取得"
        }
    }
}

extension EvidenceCode {
    public var kind: EvidenceKind {
        switch self {
        case .vpnActive, .vpnInactive, .possibleICMPRateLimiting, .intermediateHopICMPDeprioritized,
             .loadedLatencyRiseLimitedComparison: .heuristic
        case .noCellularTests, .no5GTests, .cellularRadioMetricsUnavailable, .noBaseline, .interfaceProbeUnavailable: .notTested
        case .allServerHealthChecksPassed, .serverTransferInvalid: .measured
        case .streamScalingPlateau, .fullDuplexInterference: .derived
        default:
            switch dimension {
            case .crossServer, .ipFamily, .interfaceCompare, .radioCompare, .baseline: .derived
            default: .measured
            }
        }
    }
}

/// One observed fact with the values that produced it.
public struct DiagnosticEvidence: Codable, Sendable, Hashable, Identifiable {
    public var code: EvidenceCode
    /// Human-readable statement including the measured value, e.g. "上傳 1.1 Mbps（< 3 Mbps）".
    public var statement: String
    /// Numeric value behind the statement when there is one.
    public var value: Double?
    public var unit: String?
    /// Tests in the session that produced this evidence (empty = session-level comparison).
    public var testIDs: [UUID]
    /// Interface of the source test; `nil` for session-level evidence (cross comparisons, baseline).
    public var interface: InterfaceKind?

    public var id: String { "\(code.rawValue)|\(testIDs.map(\.uuidString).joined(separator: ","))|\(statement)" }
    public var dimension: EvidenceDimension { code.dimension }
    public var kind: EvidenceKind { code.kind }

    public init(code: EvidenceCode, statement: String, value: Double? = nil, unit: String? = nil,
                testIDs: [UUID] = [], interface: InterfaceKind? = nil) {
        self.code = code
        self.statement = statement
        self.value = value
        self.unit = unit
        self.testIDs = testIDs
        self.interface = interface
    }
}
