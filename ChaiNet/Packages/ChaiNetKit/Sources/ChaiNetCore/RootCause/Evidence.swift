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

    public var displayName: String {
        switch self {
        case .device: "裝置 / 系統"
        case .localNetwork: "區域網路 / Wi-Fi"
        case .accessLink: "接取網路 / 無線電"
        case .carrierCore: "ISP / 電信核心網路"
        case .routing: "路由 / 國際互連"
        case .server: "伺服器"
        case .application: "應用協定（DNS / TLS / HTTP）"
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
    case latencySpikesFrequent
    // Bufferbloat
    case downloadBufferbloat, uploadBufferbloat, noBufferbloat
    // Application / protocol
    case dnsSlow, dnsFailures, dnsHealthy
    case tcpConnectSlow, tlsSlow, ttfbSlow
    case http3Negotiated, quicBlocked
    case mtuReduced, mtuNormal
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
    case serverThroughputOutlierLow, crossServerConsistentThroughput
    // IP family
    case ipv6DegradedOnly, ipv4DegradedOnly, ipFamiliesEquivalent, ipv6Unavailable
    // Interfaces / radio
    case wifiNormalCellularDegraded, cellularNormalWifiDegraded
    case lteNormalNRDegraded, nrNormalLTEDegraded
    case allCellularDegradedWifiNormal
    case allInterfacesDegraded, allInterfacesNormal
    // Baseline
    case deviatesFromBaseline, matchesBaseline, noBaseline

    public var dimension: EvidenceDimension {
        switch self {
        case .downloadHigh, .downloadNormal, .downloadLow, .uploadVeryLow, .uploadLow, .uploadNormal, .asymmetricRatio,
             .downloadUnstable, .downloadStable, .uploadUnstable, .uploadStable:
            .throughput
        case .idleLatencyLow, .idleLatencyHigh, .jitterHigh, .jitterLow, .latencySpikesFrequent:
            .latency
        case .lossNone, .lossHigh, .lossSevere, .lossBursty, .lossRandom:
            .loss
        case .downloadBufferbloat, .uploadBufferbloat, .noBufferbloat:
            .bufferbloat
        case .dnsSlow, .dnsFailures, .dnsHealthy:
            .dns
        case .tcpConnectSlow, .tlsSlow, .ttfbSlow, .http3Negotiated, .quicBlocked:
            .protocols
        case .mtuReduced, .mtuNormal:
            .mtu
        case .onWiFi, .onCellular, .on5G, .onLTE, .noCellularTests, .no5GTests, .vpnActive, .vpnInactive, .lowDataMode,
             .notConstrained, .serverUnhealthy, .serverHealthy, .cellularRadioMetricsUnavailable:
            .environment
        case .pathChanged, .connectionDrops, .noDropsObserved:
            .stabilityMonitoring
        case .singleServerAnomalous, .multipleServersAnomalous, .allServersAnomalous, .allServersNormal, .regionSpecificAnomaly,
             .serverThroughputOutlierLow, .crossServerConsistentThroughput:
            .crossServer
        case .ipv6DegradedOnly, .ipv4DegradedOnly, .ipFamiliesEquivalent, .ipv6Unavailable:
            .ipFamily
        case .wifiNormalCellularDegraded, .cellularNormalWifiDegraded, .allCellularDegradedWifiNormal, .allInterfacesDegraded,
             .allInterfacesNormal:
            .interfaceCompare
        case .lteNormalNRDegraded, .nrNormalLTEDegraded:
            .radioCompare
        case .deviatesFromBaseline, .matchesBaseline, .noBaseline:
            .baseline
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
