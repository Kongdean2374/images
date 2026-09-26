import Foundation
import ChaiNetCore

/// Every independently runnable tool.
enum Tool: String, CaseIterable, Identifiable, Hashable {
    case ping, jitter, packetLoss, burstLoss, download, upload, bufferbloat
    case dns, ipFamilies, http, tls, traceroute, mtu
    case continuousPing, dropMonitor
    case gaming, voice, streaming, obs
    case serverBenchmark, crossValidation, interfaceCompare, networkInfo
    // Stress engines (same code as the Extreme Stress Test)
    case stressRamp, stressSustainedDownload, stressSustainedUpload, stressFullDuplex, stressBurst, stressMultiDestination,
         stressRecovery, stressPacketLoss

    /// The stress engine this tool runs, if it is one.
    var stressKind: StressToolKind? {
        switch self {
        case .stressRamp: .streamRamp
        case .stressSustainedDownload: .sustainedDownload
        case .stressSustainedUpload: .sustainedUpload
        case .stressFullDuplex: .fullDuplex
        case .stressBurst: .burst
        case .stressMultiDestination: .multiDestination
        case .stressRecovery: .recovery
        case .stressPacketLoss: .packetLossStress
        default: nil
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ping: "Ping"
        case .jitter: "Jitter 抖動"
        case .packetLoss: "封包遺失"
        case .burstLoss: "連續遺失"
        case .download: "下載"
        case .upload: "上傳"
        case .bufferbloat: "Bufferbloat"
        case .dns: "DNS 測試"
        case .ipFamilies: "IPv4 / IPv6"
        case .http: "HTTP / TTFB / HTTP3"
        case .tls: "TCP / TLS 交握"
        case .traceroute: "路由追蹤"
        case .mtu: "MTU"
        case .continuousPing: "連續 Ping"
        case .dropMonitor: "斷線監測"
        case .gaming: "遊戲品質"
        case .voice: "語音品質"
        case .streaming: "串流品質"
        case .obs: "OBS 上傳適用性"
        case .serverBenchmark: "伺服器基準"
        case .crossValidation: "多端點交叉驗證"
        case .interfaceCompare: "Wi-Fi / 行動網路比較"
        case .networkInfo: "網路介面資訊"
        case .stressRamp: "連線數階梯（飽和點）"
        case .stressSustainedDownload: "持續下載滿載"
        case .stressSustainedUpload: "持續上傳滿載"
        case .stressFullDuplex: "全雙工滿載"
        case .stressBurst: "突發 / 階梯負載"
        case .stressMultiDestination: "多目的地同時下載"
        case .stressRecovery: "負載後恢復"
        case .stressPacketLoss: "封包遺失壓力"
        }
    }

    var subtitle: String {
        switch self {
        case .ping: "閒置延遲 min / avg / median / P95 / P99"
        case .jitter: "封包延遲變異"
        case .packetLoss: "UDP / ICMP 真實遺失率"
        case .burstLoss: "區分隨機與連續遺失"
        case .download: "多連線下載速度與穩定度"
        case .upload: "多連線上傳速度與穩定度"
        case .bufferbloat: "閒置 vs 下載 / 上傳時延遲"
        case .dns: "系統、UDP、DoH 解析器比較"
        case .ipFamilies: "同一目標分別走 IPv4 / IPv6"
        case .http: "DNS、連線、TTFB、協定協商"
        case .tls: "TCP 與 TLS 建立時間"
        case .traceroute: "ICMP 逐跳路徑（IPv4）"
        case .mtu: "DF 二分搜尋路徑 MTU（IPv4）"
        case .continuousPing: "即時延遲、突波偵測"
        case .dropMonitor: "偵測斷線與路徑變更"
        case .gaming: "50 pps 模擬遊戲封包"
        case .voice: "G.711 模擬 · MOS / R 值"
        case .streaming: "可穩定播放的最高畫質"
        case .obs: "建議直播位元率"
        case .serverBenchmark: "比較所有伺服器延遲"
        case .crossValidation: "判斷是伺服器還是你的網路"
        case .interfaceCompare: "同時比較兩種介面延遲"
        case .networkInfo: "介面、IP、VPN、制式"
        case .stressRamp: "1→32 條連線，找出吞吐量飽和點"
        case .stressSustainedDownload: "固定連線數長時間滿載下載"
        case .stressSustainedUpload: "長時間滿載上傳與上行排隊"
        case .stressFullDuplex: "上下行同時滿載的互相影響"
        case .stressBurst: "負載 / 閒置循環，量測恢復時間"
        case .stressMultiDestination: "多個節點同時下載的總量"
        case .stressRecovery: "滿載後延遲回到基準的時間"
        case .stressPacketLoss: "50 pps 壓力探測 + 多端點對照"
        }
    }

    var symbol: String {
        switch self {
        case .ping: "dot.radiowaves.left.and.right"
        case .jitter: "waveform.path.ecg"
        case .packetLoss: "drop.triangle"
        case .burstLoss: "square.stack.3d.down.forward"
        case .download: "arrow.down.circle"
        case .upload: "arrow.up.circle"
        case .bufferbloat: "hourglass"
        case .dns: "globe"
        case .ipFamilies: "point.3.connected.trianglepath.dotted"
        case .http: "network"
        case .tls: "lock.shield"
        case .traceroute: "point.topleft.down.to.point.bottomright.curvepath"
        case .mtu: "ruler"
        case .continuousPing: "timer"
        case .dropMonitor: "antenna.radiowaves.left.and.right.slash"
        case .gaming: "gamecontroller"
        case .voice: "phone.bubble"
        case .streaming: "play.tv"
        case .obs: "video.badge.waveform"
        case .serverBenchmark: "server.rack"
        case .crossValidation: "checkmark.shield"
        case .interfaceCompare: "arrow.left.arrow.right"
        case .networkInfo: "info.circle"
        case .stressRamp: "chart.line.uptrend.xyaxis"
        case .stressSustainedDownload: "arrow.down.to.line"
        case .stressSustainedUpload: "arrow.up.to.line"
        case .stressFullDuplex: "arrow.up.arrow.down"
        case .stressBurst: "waveform.path"
        case .stressMultiDestination: "point.3.filled.connected.trianglepath.dotted"
        case .stressRecovery: "arrow.uturn.backward.circle"
        case .stressPacketLoss: "bolt.horizontal"
        }
    }

    var kind: TestKind {
        switch self {
        case .gaming: .gaming
        case .voice: .voice
        case .streaming: .streaming
        case .obs: .obsUpload
        case .dns: .dnsBenchmark
        case .http, .tls, .ipFamilies: .protocolProbe
        case .traceroute: .traceroute
        case .mtu: .mtu
        case .continuousPing, .dropMonitor: .monitoring
        case .interfaceCompare: .interfaceCompare
        case .stressRamp, .stressSustainedDownload, .stressSustainedUpload, .stressFullDuplex, .stressBurst, .stressMultiDestination,
             .stressRecovery, .stressPacketLoss: .stressTool
        default: .fullSpeedTest
        }
    }

    /// Items this tool runs through the shared `TestRunner`.
    var items: Set<TestItem> {
        switch self {
        case .ping: [.ping]
        case .jitter: [.ping, .jitter]
        case .packetLoss: [.packetLoss]
        case .burstLoss: [.packetLoss, .burstLoss, .latencySpikes]
        case .download: [.download]
        case .upload: [.upload]
        case .bufferbloat: [.ping, .bufferbloat]
        case .dns: [.dns]
        case .ipFamilies: [.ipFamilies]
        case .http: [.http, .quic]
        case .tls: [.tls]
        case .traceroute: [.traceroute]
        case .mtu: [.mtu]
        case .continuousPing: [.continuousPing]
        case .dropMonitor: [.dropMonitor]
        case .gaming, .voice, .streaming, .obs: []
        case .crossValidation: [.crossValidation]
        case .interfaceCompare: [.interfaceCompare]
        case .serverBenchmark, .networkInfo: []
        case .stressRamp, .stressSustainedDownload, .stressSustainedUpload, .stressFullDuplex, .stressBurst, .stressMultiDestination,
             .stressRecovery, .stressPacketLoss: []
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case latency = "延遲與穩定度"
        case throughput = "頻寬"
        case protocols = "協定與路由"
        case monitoring = "監測"
        case quality = "情境品質"
        case environment = "伺服器與環境"
        case stress = "壓力測試元件"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .ping, .jitter, .packetLoss, .burstLoss: .latency
        case .download, .upload, .bufferbloat: .throughput
        case .dns, .ipFamilies, .http, .tls, .traceroute, .mtu: .protocols
        case .continuousPing, .dropMonitor: .monitoring
        case .gaming, .voice, .streaming, .obs: .quality
        case .serverBenchmark, .crossValidation, .interfaceCompare, .networkInfo: .environment
        case .stressRamp, .stressSustainedDownload, .stressSustainedUpload, .stressFullDuplex, .stressBurst, .stressMultiDestination,
             .stressRecovery, .stressPacketLoss: .stress
        }
    }
}
