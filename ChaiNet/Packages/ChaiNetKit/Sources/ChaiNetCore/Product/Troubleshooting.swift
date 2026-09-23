import Foundation

/// Symptoms offered by the Smart Troubleshooting Wizard.
public enum TroubleshootingSymptom: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case gamingLag
    case slowDownload
    case slowUpload
    case connectionDrops
    case slowWebsites
    case voiceProblems
    case streamingBuffering
    case cellularOnlyProblem
    case notSure

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gamingLag: "遊戲延遲 / 卡頓"
        case .slowDownload: "下載很慢"
        case .slowUpload: "上傳很慢"
        case .connectionDrops: "連線常中斷"
        case .slowWebsites: "網頁開很慢"
        case .voiceProblems: "語音 / 視訊通話斷斷續續"
        case .streamingBuffering: "影片串流一直緩衝"
        case .cellularOnlyProblem: "只有行動網路有問題"
        case .notSure: "不確定，全面檢查"
        }
    }

    public var symbolName: String {
        switch self {
        case .gamingLag: "gamecontroller"
        case .slowDownload: "arrow.down.circle"
        case .slowUpload: "arrow.up.circle"
        case .connectionDrops: "wifi.exclamationmark"
        case .slowWebsites: "safari"
        case .voiceProblems: "phone.bubble"
        case .streamingBuffering: "play.tv"
        case .cellularOnlyProblem: "antenna.radiowaves.left.and.right"
        case .notSure: "questionmark.circle"
        }
    }

    public var detail: String {
        switch self {
        case .gamingLag: "檢查延遲、抖動、遺失、突波與負載延遲。"
        case .slowDownload: "檢查下載速度、穩定度、多伺服器與 DNS。"
        case .slowUpload: "檢查上傳速度、穩定度與上傳時的延遲。"
        case .connectionDrops: "以連續監測偵測斷線與路徑變更。"
        case .slowWebsites: "檢查 DNS、TCP / TLS 交握、TTFB 與 IPv4 / IPv6。"
        case .voiceProblems: "檢查抖動、連續遺失與上行品質。"
        case .streamingBuffering: "檢查持續下載速度與穩定度。"
        case .cellularOnlyProblem: "比較 Wi-Fi 與行動網路並檢查 IPv4 / IPv6。"
        case .notSure: "執行完整診斷。"
        }
    }
}

/// Maps symptoms to the minimum set of tests needed to diagnose them.
///
/// The union of all selected symptoms' items is run; `crossValidation` is always included for
/// throughput / loss symptoms because a single server can never localise a fault.
public enum TroubleshootingPlanner {
    public static func items(for symptom: TroubleshootingSymptom) -> Set<TestItem> {
        switch symptom {
        case .gamingLag: [.ping, .jitter, .packetLoss, .burstLoss, .latencySpikes, .bufferbloat, .crossValidation, .ipFamilies]
        case .slowDownload: [.ping, .download, .crossValidation, .dns, .ipFamilies, .bufferbloat]
        case .slowUpload: [.ping, .upload, .bufferbloat, .crossValidation, .packetLoss]
        case .connectionDrops: [.continuousPing, .dropMonitor, .packetLoss, .burstLoss, .crossValidation, .interfaceCompare]
        case .slowWebsites: [.dns, .http, .tls, .quic, .ipFamilies, .ping, .mtu]
        case .voiceProblems: [.ping, .jitter, .packetLoss, .burstLoss, .upload, .bufferbloat, .crossValidation]
        case .streamingBuffering: [.download, .ping, .bufferbloat, .crossValidation, .dns]
        case .cellularOnlyProblem: [.interfaceCompare, .ipFamilies, .download, .upload, .jitter, .packetLoss, .bufferbloat, .crossValidation]
        case .notSure: TestProfile.fullDiagnostics.items
        }
    }

    public static func profile(for symptoms: Set<TroubleshootingSymptom>) -> TestProfile {
        let combined = symptoms.reduce(into: Set<TestItem>()) { $0.formUnion(Self.items(for: $1)) }
        let name = symptoms.count == 1 ? "診斷：\(symptoms.first!.displayName)" : "診斷：\(symptoms.count) 個症狀"
        return TestProfile(name: name, symbolName: "wand.and.stars", items: combined.isEmpty ? TestProfile.quickSpeed.items : combined)
    }

    /// Follow-up tests that only make sense after switching networks (manual steps).
    public static func manualSteps(for symptoms: Set<TroubleshootingSymptom>) -> [RecommendedTest] {
        var steps: [RecommendedTest] = []
        if symptoms.contains(.cellularOnlyProblem) { steps += [.repeatOnLTE, .repeatOn5G, .repeatOnWiFi] }
        if symptoms.contains(.connectionDrops) { steps.append(.repeatOnCellular) }
        return steps
    }
}
