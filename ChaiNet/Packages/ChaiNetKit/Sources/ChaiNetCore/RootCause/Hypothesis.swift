import Foundation

/// Candidate root causes. Each has a model in `HypothesisCatalog`.
public enum RootCause: String, Codable, Sendable, Hashable, CaseIterable {
    case wifiRadioQuality
    case localNetworkCongestion
    case routerBufferbloat
    case fixedLineUplinkCongestion
    case asymmetricPlanLimit
    case cellularUplinkCongestion
    case cellularRadioQuality
    case nrSpecificIssue
    case cellularSubsystem
    case ispOrCarrierCongestion
    case serverOrRouteSpecific
    case serverCapacityLimit
    case routingTransit
    case ipv6RoutingIssue
    case ipv4RoutingIssue
    case dnsResolverIssue
    case vpnOverhead
    case lowDataModeThrottling
    case mtuTunnelIssue
    case udpQuicBlocked
    case intermittentOutage
    case deviceOrOSEnvironment
}

/// Verbal likelihood, always shown together with a numeric confidence.
public enum Likelihood: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case likely
    case possible
    case unlikely
    case insufficientEvidence
    case ruledOut

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .likely: "可能性高（Likely）"
        case .possible: "有可能（Possible）"
        case .unlikely: "可能性低（Unlikely）"
        case .insufficientEvidence: "證據不足（Insufficient evidence）"
        case .ruledOut: "已排除（Ruled out）"
        }
    }
}

/// A verification test the user (or the app) can run next.
public enum RecommendedTest: String, Codable, Sendable, Hashable, CaseIterable {
    case repeatOnLTE
    case repeatOn5G
    case repeatOnWiFi
    case repeatOnCellular
    case testAlternateServers
    case compareIPFamilies
    case runTraceroute
    case runMTUTest
    case runDNSBenchmark
    case runContinuousMonitor
    case runBufferbloatTest
    case disableVPNAndRepeat
    case disableLowDataMode
    case moveCloserToRouter
    case repeatAtDifferentTime
    case pauseOtherDevices
    case runProtocolProbe
    case restartDeviceNetwork
    case contactProvider

    public var title: String {
        switch self {
        case .repeatOnLTE: "切換到 LTE 後重測"
        case .repeatOn5G: "切換到 5G 後重測"
        case .repeatOnWiFi: "連上 Wi-Fi 後重測"
        case .repeatOnCellular: "改用行動網路重測"
        case .testAlternateServers: "以其他伺服器交叉驗證"
        case .compareIPFamilies: "IPv4 / IPv6 分別測試"
        case .runTraceroute: "執行路由追蹤"
        case .runMTUTest: "執行 MTU 測試"
        case .runDNSBenchmark: "執行 DNS 測試"
        case .runContinuousMonitor: "執行連續監測（≥ 5 分鐘）"
        case .runBufferbloatTest: "執行 Bufferbloat 測試"
        case .disableVPNAndRepeat: "關閉 VPN 後重測"
        case .disableLowDataMode: "關閉低數據模式後重測"
        case .moveCloserToRouter: "靠近路由器或改用 5/6 GHz 後重測"
        case .repeatAtDifferentTime: "於離峰時段重測"
        case .pauseOtherDevices: "暫停其他裝置的大量傳輸後重測"
        case .runProtocolProbe: "執行 HTTP / TLS / QUIC 協定分析"
        case .restartDeviceNetwork: "開關飛航模式後重測"
        case .contactProvider: "附上報告聯絡 ISP / 電信商"
        }
    }

    /// How to perform it on iOS, including platform limits.
    public var howTo: String {
        switch self {
        case .repeatOnLTE:
            "iOS 不允許 App 強制切換制式：請到「設定 > 行動服務 > 語音與數據」選擇 LTE，再回到 ChaiNet 將測試加入同一個診斷工作階段。"
        case .repeatOn5G:
            "請到「設定 > 行動服務 > 語音與數據」選擇「5G 開啟」，再將測試加入同一個診斷工作階段。"
        case .repeatOnWiFi, .repeatOnCellular:
            "切換網路後將測試加入同一個診斷工作階段；ChaiNet 也可在 Wi-Fi 下透過行動網路介面直接做延遲比較。"
        case .testAlternateServers: "在工具頁執行「伺服器基準測試」，或於診斷中啟用自動交叉驗證。"
        case .compareIPFamilies: "在工具頁執行「IPv4 / IPv6」，分別強制使用兩種協定量測。"
        case .runTraceroute: "工具頁 > 路由追蹤（ICMP，僅 IPv4）。"
        case .runMTUTest: "工具頁 > MTU（ICMP + DF，僅 IPv4）。"
        case .runDNSBenchmark: "工具頁 > DNS 測試。"
        case .runContinuousMonitor: "工具頁 > 連續 Ping / 斷線監測，保持 App 在前景。"
        case .runBufferbloatTest: "工具頁 > Bufferbloat。"
        case .disableVPNAndRepeat: "暫時關閉 VPN / iCloud 私密轉送後重測。"
        case .disableLowDataMode: "設定 > Wi-Fi 或行動服務 > 關閉低數據模式。"
        case .moveCloserToRouter: "縮短與路由器距離，或連接 5 GHz / 6 GHz SSID。"
        case .repeatAtDifferentTime: "尖峰（晚間）與離峰（清晨）各測一次比較。"
        case .pauseOtherDevices: "暫停同網路中其他裝置的下載、備份、串流。"
        case .runProtocolProbe: "工具頁 > HTTP / TLS。"
        case .restartDeviceNetwork: "開啟飛航模式 10 秒後關閉，重新註冊網路。"
        case .contactProvider: "匯出技術報告（JSON / 文字）提供給 ISP 或電信商。"
        }
    }
}

/// Result of evaluating one root cause against the evidence.
public struct DiagnosticHypothesis: Codable, Sendable, Hashable, Identifiable {
    public var cause: RootCause
    public var layer: NetworkLayer
    public var title: String
    public var explanation: String
    public var supportingEvidence: [DiagnosticEvidence]
    public var contradictingEvidence: [DiagnosticEvidence]
    /// Evidence that decisively excludes this cause (non-empty ⇒ `.ruledOut`).
    public var rulingOutEvidence: [DiagnosticEvidence]
    /// Dimensions this hypothesis needs but that were not measured.
    public var missingDimensions: [EvidenceDimension]
    /// 0…1.
    public var confidence: Double
    public var likelihood: Likelihood
    public var recommendedNextTests: [RecommendedTest]
    /// Caveats such as "iOS does not expose RSRP/SINR".
    public var limitations: [String]

    public var id: RootCause { cause }
    public var confidencePercent: Int { Int((confidence * 100).rounded()) }
}
