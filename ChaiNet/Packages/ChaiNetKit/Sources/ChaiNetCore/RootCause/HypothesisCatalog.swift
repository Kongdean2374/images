import Foundation

/// Which tests' evidence a hypothesis looks at.
public enum EvidenceScope: String, Codable, Sendable, Hashable {
    /// All evidence.
    case all
    /// Only evidence from cellular tests + session-level evidence.
    case cellular
    /// Only evidence from Wi-Fi / Ethernet tests + session-level evidence.
    case fixed
}

/// Data-driven model of one root cause.
///
/// The analyzer scores it with log-odds accumulation (a naive-Bayes style evidence model):
///
///     s          = prior + Σ_{c ∈ present codes} weight(c)
///     confidence = min(cap, 1 / (1 + e^(−s)))
///
/// `weight > 0` → supporting evidence, `weight < 0` → contradicting evidence. Each code counts
/// once no matter how many tests produced it, so repeating the same test does not inflate
/// confidence. Typical magnitudes: 0.3 weak, 0.7–1.0 moderate, 1.5–2.5 strong.
public struct HypothesisModel: Sendable {
    public var cause: RootCause
    public var layer: NetworkLayer
    public var title: String
    public var explanation: String
    public var prior: Double
    public var weights: [EvidenceCode: Double]
    /// Any of these present ⇒ `.ruledOut`.
    public var ruledOutBy: Set<EvidenceCode>
    /// If non-empty, at least one must be present for the hypothesis to apply. When none is
    /// present the cause was **not tested** in this session (never "ruled out").
    public var requiresAny: Set<EvidenceCode>
    /// Codes proving the required condition is absent (e.g. `notConstrained` for Low Data Mode).
    /// Measured absence → `.ruledOut` only when `absenceIsDecisive`; otherwise `.unlikely`.
    public var notApplicableWhen: Set<EvidenceCode>
    /// True only when the absence observation is authoritative (e.g. `NWPath.isConstrained`).
    public var absenceIsDecisive: Bool = false
    /// Human description of what `requiresAny` needs, for "not tested" explanations.
    public var requirement: String = ""
    public var scope: EvidenceScope
    /// Without these dimensions the hypothesis can be at most "possible" (confidence capped
    /// at `incompleteCap`) and falls to "insufficient evidence" below 0.40.
    public var requiredDimensions: Set<EvidenceDimension>
    /// Hard ceiling — e.g. radio hypotheses can never be certain because iOS hides RSRP/SINR.
    public var confidenceCap: Double
    public var verificationTests: [RecommendedTest]
    public var limitations: [String]
    /// While any of these is present the hypothesis can't be ruled out (e.g. an unexplained
    /// invalid server transfer keeps "server / route specific" open whatever other checks say).
    public var ruleOutBlockedBy: Set<EvidenceCode> = []
    /// The ruling-out controls only cover the *broad* form of this cause (one target / one
    /// transport): ruling-out evidence yields `.broadIssueUnlikely`, never `.ruledOut`.
    public var scopedRuleOut: Bool = false
    /// When this measured condition is present the hypothesis is `.supported` (the condition is a
    /// fact; its mechanism / location stays a hypothesis).
    public var observedCondition: EvidenceCode?

    public static let incompleteCap = 0.6
    public static let defaultPrior = -1.5
}

public enum HypothesisCatalog {
    static let noRadioMetrics = "iOS 無法提供 RSRP / RSRQ / SINR / 頻段 / Cell ID，無法直接驗證無線電狀況，信心度已設上限。"
    static let noWiFiRSSI = "iOS 無法提供 Wi-Fi RSSI / 雜訊 / 頻道資訊，只能從延遲與遺失型態推論。"

    public static let all: [HypothesisModel] = [
        HypothesisModel(
            cause: .wifiRadioQuality, layer: .localNetwork, title: "Wi-Fi 無線品質不佳（干擾 / 訊號弱）",
            explanation: "Wi-Fi 重傳與空中時間競爭會造成隨機遺失、抖動與延遲突波，且只發生在 Wi-Fi 上。",
            prior: HypothesisModel.defaultPrior,
            weights: [.jitterHigh: 0.8, .lossRandom: 0.8, .lossHigh: 0.4, .possibleICMPRateLimiting: -0.3, .latencySpikesFrequent: 0.7, .downloadUnstable: 0.5,
                      .uploadUnstable: 0.3, .cellularNormalWifiDegraded: 2.0, .allServersAnomalous: 0.4, .multipleServersAnomalous: 0.3,
                      .singleServerAnomalous: -1.5, .jitterLow: -1.0, .lossNone: -0.6, .noConfirmedGeneralLoss: -0.6, .deviatesFromBaseline: 0.4, .matchesBaseline: -0.4],
            ruledOutBy: [.wifiNormalCellularDegraded], requiresAny: [.onWiFi], notApplicableWhen: [], requirement: "Wi-Fi 測試",
            scope: .fixed, requiredDimensions: [.latency, .loss], confidenceCap: 0.85,
            verificationTests: [.moveCloserToRouter, .repeatOnCellular, .runContinuousMonitor], limitations: [noWiFiRSSI]),

        HypothesisModel(
            cause: .localNetworkCongestion, layer: .localNetwork, title: "區域網路壅塞（其他裝置佔用頻寬）",
            explanation: "同網路其他裝置的下載、備份或串流會佔滿頻寬並推高延遲，通常相對歷史基準明顯變差。",
            prior: HypothesisModel.defaultPrior,
            weights: [.downloadBufferbloat: 0.6, .uploadBufferbloat: 0.6, .deviatesFromBaseline: 0.9, .downloadUnstable: 0.5,
                      .cellularNormalWifiDegraded: 1.0, .allServersAnomalous: 0.4, .idleLatencyHigh: 0.4,
                      .matchesBaseline: -1.0, .singleServerAnomalous: -1.5, .noBufferbloat: -0.6],
            ruledOutBy: [.wifiNormalCellularDegraded], requiresAny: [.onWiFi], notApplicableWhen: [], requirement: "Wi-Fi 測試",
            scope: .fixed, requiredDimensions: [.throughput, .baseline], confidenceCap: 0.8,
            verificationTests: [.pauseOtherDevices, .repeatAtDifferentTime], limitations: ["App 無法看到同網路其他裝置的流量。"]),

        HypothesisModel(
            cause: .loadedLatencyInflation, layer: .pathQueueing, title: "負載延遲上升（網路路徑佇列，位置未知）",
            explanation: "滿載時延遲明顯上升，代表封包在路徑上某處排隊（queue_location=unknown）。可能位置：裝置 / 數據機佇列、無線電排程器、接取網路、電信商 / 核心網路、路由器、遠端路徑。沒有額外證據時不指定實體位置。",
            prior: HypothesisModel.defaultPrior,
            // The measured condition (≥ 30 ms rise on a valid load) carries the weight; > 100 ms codes are
            // the same measurement, so they only add a severity increment (no double counting).
            weights: [.loadedLatencyInflationObserved: 2.0, .loadedLatencyRiseLimitedComparison: 1.2, .downloadBufferbloat: 0.3, .uploadBufferbloat: 0.3, .idleLatencyLow: 0.3,
                      .jitterHigh: 0.3, .slowPostLoadRecovery: 0.5],
            ruledOutBy: [.noBufferbloat], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.bufferbloat], confidenceCap: 0.95,
            verificationTests: [.runBufferbloatTest, .repeatOnWiFi, .repeatOnCellular, .repeatAtDifferentTime],
            limitations: ["iPhone 端無法確認佇列位於哪一跳（device/modem、radio scheduler、access、carrier/core、router、remote path 皆有可能）；需以不同網路 / 不同時段比較來縮小範圍。"],
            observedCondition: .loadedLatencyInflationObserved),

        HypothesisModel(
            cause: .fixedLineUplinkCongestion, layer: .accessLink, title: "固網上行壅塞",
            explanation: "下行正常但上行極低且不穩，並伴隨上傳時延遲上升，代表固網上行鏈路被佔滿或壅塞。",
            prior: HypothesisModel.defaultPrior,
            weights: [.uploadVeryLow: 1.5, .uploadLow: 0.6, .downloadHigh: 0.7, .uploadUnstable: 1.0, .uploadBufferbloat: 1.0,
                      .allServersAnomalous: 0.5, .asymmetricRatio: 0.3, .uploadStable: -1.0, .singleServerAnomalous: -1.5,
                      .uploadNormal: -1.2],
            ruledOutBy: [], requiresAny: [.onWiFi], notApplicableWhen: [], requirement: "Wi-Fi / 有線測試",
            scope: .fixed, requiredDimensions: [.throughput], confidenceCap: 0.9,
            verificationTests: [.pauseOtherDevices, .testAlternateServers, .repeatAtDifferentTime], limitations: []),

        HypothesisModel(
            cause: .asymmetricPlanLimit, layer: .accessLink, title: "方案上行頻寬限制（正常現象）",
            explanation: "上行穩定但遠低於下行，且沒有遺失或排隊延遲，較符合 ISP 方案本身的上下行不對稱，而不是故障。",
            prior: HypothesisModel.defaultPrior,
            weights: [.asymmetricRatio: 1.0, .uploadStable: 1.5, .lossNone: 0.5, .noConfirmedGeneralLoss: 0.5, .noBufferbloat: 0.3, .onCellular: -0.5,
                      .uploadUnstable: -1.5, .lossHigh: -1.0, .uploadBufferbloat: -0.5, .deviatesFromBaseline: -1.0, .matchesBaseline: 0.5],
            ruledOutBy: [], requiresAny: [.asymmetricRatio, .uploadLow, .uploadVeryLow], notApplicableWhen: [.uploadNormal],
            requirement: "上傳頻寬測試",
            scope: .all, requiredDimensions: [.throughput], confidenceCap: 0.9,
            verificationTests: [.contactProvider], limitations: []),

        HypothesisModel(
            cause: .cellularUplinkCongestion, layer: .accessLink, title: "行動網路上行壅塞（基地台負載 / 電信商排程）",
            explanation: "下行容量正常但上行極低且不穩，並伴隨抖動、遺失與上傳時延遲上升；多個伺服器表現一致時，瓶頸位於行動網路上行而非伺服器。",
            prior: HypothesisModel.defaultPrior,
            weights: [.downloadHigh: 0.7, .uploadVeryLow: 1.0, .uploadLow: 0.4, .uploadUnstable: 1.0, .uploadBufferbloat: 1.0,
                      .throughputDegradationUnderLoad: 0.5,
                      .jitterHigh: 0.5, .lossHigh: 0.3, .lossSevere: 0.3, .allServersAnomalous: 0.7, .multipleServersAnomalous: 0.4,
                      .deviatesFromBaseline: 0.5, .wifiNormalCellularDegraded: 0.5,
                      .idleLatencyLow: -0.3, .singleServerAnomalous: -1.5, .uploadStable: -1.0, .matchesBaseline: -0.5,
                      .uploadNormal: -1.0, .cellularNormalWifiDegraded: -2.0],
            ruledOutBy: [], requiresAny: [.onCellular], notApplicableWhen: [], requirement: "行動網路測試",
            scope: .cellular, requiredDimensions: [.throughput], confidenceCap: 0.85,
            verificationTests: [.repeatOnLTE, .repeatAtDifferentTime, .testAlternateServers], limitations: [noRadioMetrics]),

        HypothesisModel(
            cause: .cellularRadioQuality, layer: .accessLink, title: "行動網路無線電品質不佳（訊號邊緣 / 室內）",
            explanation: "上行受手機發射功率限制，訊號邊緣時上行先崩潰，並出現連續遺失；由於無法讀取 RSRP / SINR，只能間接推論。",
            prior: HypothesisModel.defaultPrior,
            weights: [.uploadVeryLow: 1.0, .uploadUnstable: 0.8, .downloadUnstable: 0.5, .lossHigh: 0.7, .lossBursty: 0.5,
                      .jitterHigh: 0.5, .allServersAnomalous: 0.5, .wifiNormalCellularDegraded: 0.7, .downloadLow: 0.5,
                      .singleServerAnomalous: -1.5, .uploadStable: -0.8, .lossNone: -0.8, .noConfirmedGeneralLoss: -0.8, .cellularNormalWifiDegraded: -2.5],
            ruledOutBy: [], requiresAny: [.onCellular], notApplicableWhen: [], requirement: "行動網路測試",
            scope: .cellular, requiredDimensions: [.throughput, .loss], confidenceCap: 0.65,
            verificationTests: [.repeatOnLTE, .restartDeviceNetwork], limitations: [noRadioMetrics]),

        HypothesisModel(
            cause: .nrSpecificIssue, layer: .accessLink, title: "5G 專屬問題（5G 無線電 / 電信商設定 / 5G 上行）",
            explanation: "LTE 正常而 5G 異常，問題集中在 5G 無線電、NSA 錨點設定或 5G 上行路徑。",
            prior: HypothesisModel.defaultPrior,
            weights: [.lteNormalNRDegraded: 2.5, .on5G: 0.3, .allCellularDegradedWifiNormal: -0.7],
            ruledOutBy: [.nrNormalLTEDegraded], requiresAny: [.on5G], notApplicableWhen: [], requirement: "5G 測試",
            scope: .cellular, requiredDimensions: [.radioCompare], confidenceCap: 0.85,
            verificationTests: [.repeatOnLTE, .repeatOn5G], limitations: [noRadioMetrics]),

        HypothesisModel(
            cause: .cellularSubsystem, layer: .carrierCore, title: "行動網路子系統（電信商 / SIM / APN / 數據機路徑）",
            explanation: "LTE 與 5G 皆異常但 Wi-Fi 正常：問題在行動數據路徑本身，而非 App 或 iOS 網路層。",
            prior: -2.0,
            weights: [.allCellularDegradedWifiNormal: 2.5, .wifiNormalCellularDegraded: 1.0, .lteNormalNRDegraded: -1.0,
                      .nrNormalLTEDegraded: -1.0, .allInterfacesDegraded: -1.0],
            ruledOutBy: [.cellularNormalWifiDegraded, .allInterfacesNormal], requiresAny: [.onCellular], notApplicableWhen: [],
            requirement: "行動網路測試",
            scope: .all, requiredDimensions: [.interfaceCompare], confidenceCap: 0.8,
            verificationTests: [.repeatOnWiFi, .restartDeviceNetwork, .contactProvider], limitations: [noRadioMetrics]),

        HypothesisModel(
            cause: .ispOrCarrierCongestion, layer: .carrierCore, title: "ISP / 電信商網路壅塞",
            explanation: "所有獨立伺服器同時異常，且相對歷史基準變差，較可能是 ISP 或電信商網路的問題。",
            prior: HypothesisModel.defaultPrior,
            weights: [.allServersAnomalous: 1.5, .multipleServersAnomalous: 1.0, .deviatesFromBaseline: 0.7, .lossHigh: 0.5,
                      .throughputDegradationUnderLoad: 0.5, .crossProviderThroughputConsistent: 0.2,
                      .idleLatencyHigh: 0.5, .singleServerAnomalous: -2.0, .allServersNormal: -1.5, .matchesBaseline: -0.7,
                      .cellularNormalWifiDegraded: -0.3],
            ruledOutBy: [], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.crossServer], confidenceCap: 0.85,
            verificationTests: [.testAlternateServers, .repeatAtDifferentTime, .runTraceroute, .contactProvider], limitations: []),

        HypothesisModel(
            cause: .serverOrRouteSpecific, layer: .server, title: "一般伺服器 / 路由問題（generalServerOrRouteIssue）",
            explanation: "測速伺服器或其路由整體異常（吞吐量 / 健康檢查 / 回應時間），而非你的網路。僅少數端點的 ICMP 遺失另見「特定端點路徑問題」。",
            prior: HypothesisModel.defaultPrior,
            // Normal latency on some servers can't exclude one endpoint / path: allServersNormal only
            // lowers the score. Every server anomalous (a general problem) is the orthogonal control.
            weights: [.singleServerAnomalous: 2.5, .regionSpecificAnomaly: 1.0, .serverUnhealthy: 1.5, .ttfbSlow: 0.5,
                      .serverTransferInvalid: 1.5, .multipleServersAnomalous: -1.0,
                      .serverHealthy: -0.3, .allServersNormal: -1.5],
            ruledOutBy: [.allServersAnomalous], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.crossServer], confidenceCap: 0.9,
            verificationTests: [.testAlternateServers, .runTraceroute], limitations: [],
            ruleOutBlockedBy: [.serverTransferInvalid]),

        HypothesisModel(
            cause: .endpointSpecificPathIssue, layer: .server, title: "特定端點 / 業者路徑問題",
            explanation: "只有特定業者的端點（例如 Cloudflare）出現遺失，且延遲明顯高於其他獨立端點，而 Google / Apple 等對照正常：問題可能在通往該業者的路徑或其邊緣節點。ICMP 遺失也可能是端點對 ICMP 限速，因此最多只到「可能」，不代表該業者路由故障。",
            prior: HypothesisModel.defaultPrior,
            weights: [.endpointSpecificLossObserved: 1.5, .endpointLatencyElevatedVsPeers: 0.8, .singleServerAnomalous: 0.8,
                      .regionSpecificAnomaly: 0.5, .possibleICMPRateLimiting: -0.3, .allServersAnomalous: -1.5],
            ruledOutBy: [], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.loss], confidenceCap: 0.65,
            verificationTests: [.testAlternateServers, .runTraceroute, .repeatAtDifferentTime],
            limitations: ["ICMP 遺失可能是端點限速（rate limiting），無法由 iPhone 端排除；需以 TCP / HTTP 或不同時段重測確認。"]),

        HypothesisModel(
            cause: .serverCapacityLimit, layer: .server, title: "測速伺服器頻寬限制",
            explanation: "某伺服器測得的速度明顯低於其他伺服器，代表瓶頸在該伺服器的容量而非你的線路。",
            prior: HypothesisModel.defaultPrior,
            weights: [.serverThroughputOutlierLow: 2.5, .serverUnhealthy: 1.0, .largeCrossProviderThroughputVariance: 1.0,
                      .serverTransferInvalid: 1.0, .crossProviderThroughputConsistent: -1.5],
            ruledOutBy: [.crossServerConsistentThroughput], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.crossServer], confidenceCap: 0.9,
            verificationTests: [.testAlternateServers], limitations: []),

        HypothesisModel(
            cause: .routingTransit, layer: .routing, title: "路由 / 國際互連問題",
            explanation: "異常集中在特定區域的伺服器，較符合 ISP 對外互連或跨境路由問題。",
            prior: HypothesisModel.defaultPrior,
            weights: [.regionSpecificAnomaly: 2.0, .singleServerAnomalous: 0.5, .idleLatencyHigh: 0.5, .higherLatencyRelativeToPeers: 0.3,
                      .routeLatencyStep: 0.8, .largeCrossProviderThroughputVariance: 0.8,
                      .allServersNormal: -1.5, .allServersAnomalous: -1.0],
            ruledOutBy: [], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.crossServer], confidenceCap: 0.85,
            verificationTests: [.runTraceroute, .testAlternateServers], limitations: []),

        HypothesisModel(
            cause: .ipv6RoutingIssue, layer: .routing, title: "IPv6 路由 / ISP IPv6 路徑異常",
            explanation: "只有 IPv6 延遲偏高或遺失，IPv4 正常；代表 ISP 的 IPv6 路徑有問題，而非整體網路故障。",
            prior: HypothesisModel.defaultPrior,
            weights: [.ipv6DegradedOnly: 3.0, .alternateIPv6ResolverDegraded: 0.6],
            ruledOutBy: [.ipFamiliesEquivalent, .ipv4DegradedOnly], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.ipFamily], confidenceCap: 0.9,
            verificationTests: [.compareIPFamilies, .runTraceroute, .contactProvider], limitations: ["路由追蹤目前僅支援 IPv4。"],
            scopedRuleOut: true),

        HypothesisModel(
            cause: .ipv6SpecificPathIssue, layer: .routing, title: "特定 IPv6 路徑 / 傳輸異常（例如某 IPv6 DNS 解析器）",
            explanation: "單一 IPv6 目標或傳輸（例如 UDP 53 到某 IPv6 解析器）出現失敗或高延遲，但其他 IPv6 目標正常；問題侷限於該路徑而非整體 IPv6。",
            prior: HypothesisModel.defaultPrior,
            weights: [.alternateIPv6ResolverDegraded: 2.0, .ipv6DegradedOnly: 1.0, .ipv6Unavailable: 0.5],
            ruledOutBy: [], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [], confidenceCap: 0.8,
            verificationTests: [.runDNSBenchmark, .compareIPFamilies], limitations: ["只測到少數 IPv6 目標；無法代表所有 IPv6 路徑。"]),

        HypothesisModel(
            cause: .ipv4RoutingIssue, layer: .routing, title: "IPv4 路徑異常（CGNAT / IPv4 路由）",
            explanation: "只有 IPv4 異常而 IPv6 正常，常見於電信商 CGNAT 閘道壅塞或 IPv4 專屬路由問題。",
            prior: HypothesisModel.defaultPrior,
            weights: [.ipv4DegradedOnly: 3.0],
            ruledOutBy: [.ipFamiliesEquivalent, .ipv6DegradedOnly], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.ipFamily], confidenceCap: 0.9,
            verificationTests: [.compareIPFamilies, .runTraceroute], limitations: ["IPv4 / IPv6 比較只針對單一目標。"],
            scopedRuleOut: true),

        HypothesisModel(
            cause: .dnsResolverIssue, layer: .application, title: "DNS 解析器緩慢或失敗",
            explanation: "網頁「開很慢」但測速正常時，常是 DNS 解析緩慢或失敗。",
            prior: HypothesisModel.defaultPrior,
            // One healthy system-resolver median never rules DNS out globally: it lowers confidence,
            // while tail latency and degraded alternate resolvers keep the question open.
            weights: [.dnsSlow: 2.0, .dnsFailures: 2.5, .dnsHighTailLatency: 0.8, .dnsHighTailLatencyObserved: 0.8,
                      .alternateIPv6ResolverDegraded: 0.3, .dnsTransportSpecificIssue: 0.8, .dnsDomainSpecificOutlier: -0.3,
                      .systemDNSHealthy: -1.5, .dnsHealthy: -1.5],
            ruledOutBy: [], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.dns], confidenceCap: 0.9,
            verificationTests: [.runDNSBenchmark], limitations: []),

        HypothesisModel(
            cause: .vpnOverhead, layer: .device, title: "VPN 通道造成的額外延遲或限制",
            explanation: "流量經由 VPN 伺服器繞行，會增加延遲、降低 MTU，並使結果反映 VPN 而非原生線路。",
            prior: HypothesisModel.defaultPrior,
            weights: [.vpnActive: 1.0, .idleLatencyHigh: 0.7, .mtuReduced: 0.5, .allServersAnomalous: 0.3],
            ruledOutBy: [], requiresAny: [.vpnActive], notApplicableWhen: [.vpnInactive], requirement: "偵測到 VPN",
            scope: .all, requiredDimensions: [.environment], confidenceCap: 0.8,
            verificationTests: [.disableVPNAndRepeat], limitations: ["iOS 沒有公開的 VPN 狀態 API，VPN 偵測為啟發式判斷。"]),

        HypothesisModel(
            cause: .lowDataModeThrottling, layer: .device, title: "低數據模式限制",
            explanation: "iOS 低數據模式會限制部分網路行為，可能拉低測速結果。",
            prior: HypothesisModel.defaultPrior,
            weights: [.lowDataMode: 2.5],
            ruledOutBy: [], requiresAny: [.lowDataMode], notApplicableWhen: [.notConstrained], absenceIsDecisive: true,
            requirement: "低數據模式開啟",
            scope: .all, requiredDimensions: [.environment], confidenceCap: 0.8,
            verificationTests: [.disableLowDataMode], limitations: []),

        HypothesisModel(
            cause: .mtuTunnelIssue, layer: .accessLink, title: "MTU / 通道封裝問題",
            explanation: "路徑 MTU 偏小（VPN、PPPoE、行動網路通道）可能導致大封包遺失或 TLS 交握異常。",
            prior: HypothesisModel.defaultPrior,
            weights: [.mtuReduced: 1.5, .tlsSlow: 0.5, .vpnActive: 0.3, .mtuNormal: -2.0, .pathMTUObserved: -1.0],
            ruledOutBy: [], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.mtu], confidenceCap: 0.8,
            verificationTests: [.runMTUTest], limitations: ["MTU 測試僅支援 IPv4 ICMP、僅代表受測路徑；其他目的地或 IPv6 路徑可能不同。"]),

        HypothesisModel(
            cause: .udpQuicBlocked, layer: .application, title: "UDP / QUIC 被阻擋",
            explanation: "TCP 上的 HTTP 正常，但多個獨立端點的 QUIC 交握都逾時，較符合網路（企業防火牆、公共 Wi-Fi）阻擋 UDP 443；會影響 HTTP/3 與部分遊戲語音。",
            prior: HypothesisModel.defaultPrior,
            weights: [.quicBlocked: 2.5, .quicEndpointFailure: 0.3, .quicImplementationFailure: -0.5],
            ruledOutBy: [.http3Negotiated, .quicReachable], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.protocols], confidenceCap: 0.85,
            verificationTests: [.runProtocolProbe, .repeatOnCellular], limitations: []),

        HypothesisModel(
            cause: .intermittentOutage, layer: .accessLink, title: "間歇性斷線",
            explanation: "連續監測中出現多個封包全數無回應的時段，或網路路徑頻繁切換。",
            prior: HypothesisModel.defaultPrior,
            weights: [.connectionDrops: 2.5, .pathChanged: 1.0, .lossBursty: 0.7, .noDropsObserved: -1.5],
            ruledOutBy: [], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.stabilityMonitoring], confidenceCap: 0.9,
            verificationTests: [.runContinuousMonitor], limitations: ["iOS 背景執行受限，無法長時間在背景每秒監測。"]),

        HypothesisModel(
            cause: .deviceOrOSEnvironment, layer: .device, title: "裝置 / iOS / App 環境問題",
            explanation: "只有在所有網路（Wi-Fi、LTE、5G）都異常時，才提高裝置本身、iOS、VPN 設定或 App 環境的可能性。",
            prior: -2.5,
            weights: [.allInterfacesDegraded: 2.5, .allServersAnomalous: 0.3, .vpnActive: 0.5,
                      .wifiNormalCellularDegraded: -2.0, .cellularNormalWifiDegraded: -2.0, .lteNormalNRDegraded: -1.5,
                      .nrNormalLTEDegraded: -1.5, .singleServerAnomalous: -1.0],
            ruledOutBy: [.allInterfacesNormal], requiresAny: [], notApplicableWhen: [],
            scope: .all, requiredDimensions: [.interfaceCompare], confidenceCap: 0.65,
            verificationTests: [.repeatOnWiFi, .repeatOnCellular, .disableVPNAndRepeat, .restartDeviceNetwork],
            limitations: ["無法直接檢測手機硬體（天線、數據機），沒有跨網路比較時不做此判定。"]),
    ]

    public static func model(for cause: RootCause) -> HypothesisModel? {
        all.first { $0.cause == cause }
    }
}
