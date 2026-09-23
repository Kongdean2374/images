import Foundation

/// Every independently runnable measurement. Custom tests and profiles are sets of these.
public enum TestItem: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case ping
    case jitter
    case packetLoss
    case burstLoss
    case latencySpikes
    case download
    case upload
    case bufferbloat
    case dns
    case ipFamilies
    case http
    case tls
    case quic
    case traceroute
    case mtu
    case crossValidation
    case interfaceCompare
    case continuousPing
    case dropMonitor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ping: "Ping"
        case .jitter: "Jitter 抖動"
        case .packetLoss: "封包遺失"
        case .burstLoss: "連續遺失（Burst Loss）"
        case .latencySpikes: "延遲突波"
        case .download: "下載"
        case .upload: "上傳"
        case .bufferbloat: "Bufferbloat"
        case .dns: "DNS 測試"
        case .ipFamilies: "IPv4 / IPv6"
        case .http: "HTTP 延遲 / TTFB"
        case .tls: "TCP / TLS 交握"
        case .quic: "HTTP/3 / QUIC"
        case .traceroute: "路由追蹤"
        case .mtu: "MTU"
        case .crossValidation: "多伺服器交叉驗證"
        case .interfaceCompare: "Wi-Fi / 行動網路比較"
        case .continuousPing: "連續 Ping"
        case .dropMonitor: "斷線監測"
        }
    }

    public var symbolName: String {
        switch self {
        case .ping: "dot.radiowaves.left.and.right"
        case .jitter: "waveform.path.ecg"
        case .packetLoss: "drop.triangle"
        case .burstLoss: "square.stack.3d.down.forward"
        case .latencySpikes: "bolt.horizontal"
        case .download: "arrow.down.circle"
        case .upload: "arrow.up.circle"
        case .bufferbloat: "hourglass"
        case .dns: "globe"
        case .ipFamilies: "point.3.connected.trianglepath.dotted"
        case .http: "network"
        case .tls: "lock.shield"
        case .quic: "bolt.circle"
        case .traceroute: "point.topleft.down.to.point.bottomright.curvepath"
        case .mtu: "ruler"
        case .crossValidation: "server.rack"
        case .interfaceCompare: "arrow.left.arrow.right"
        case .continuousPing: "timer"
        case .dropMonitor: "antenna.radiowaves.left.and.right.slash"
        }
    }

    /// Items that share the same underlying probe run (ping/jitter/loss/burst/spikes all come
    /// from one latency probe sequence, so selecting any of them runs it once).
    public var usesLatencyProbe: Bool {
        [.ping, .jitter, .packetLoss, .burstLoss, .latencySpikes].contains(self)
    }

    /// Rough mobile-data cost at the default duration (MB), shown before running on cellular.
    public var estimatedDataMB: Double {
        switch self {
        case .download: 150
        case .upload: 60
        case .bufferbloat: 200
        default: 0.2
        }
    }
}

/// A saved or one-off selection of test items.
public struct TestProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var items: Set<TestItem>
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, symbolName: String, items: Set<TestItem>, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.items = items
        self.isBuiltIn = isBuiltIn
    }

    /// Execution order: cheap/idle measurements first so load tests can't disturb them.
    public var orderedItems: [TestItem] {
        TestItem.allCases.filter { items.contains($0) }
    }

    public var estimatedDataMB: Double {
        orderedItems.reduce(0) { $0 + $1.estimatedDataMB }
    }

    // Stable IDs so built-ins can be referenced from settings.
    static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0xC4, 0xA1, 0x4E, 0x70, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n))
    }

    public static let quickSpeed = TestProfile(id: fixedID(1), name: "快速測速", symbolName: "speedometer",
                                               items: [.ping, .jitter, .download, .upload], isBuiltIn: true)
    public static let gaming = TestProfile(id: fixedID(2), name: "遊戲", symbolName: "gamecontroller",
                                           items: [.ping, .jitter, .packetLoss, .burstLoss, .latencySpikes], isBuiltIn: true)
    public static let cellular = TestProfile(id: fixedID(3), name: "行動網路", symbolName: "antenna.radiowaves.left.and.right",
                                             items: [.download, .upload, .jitter, .packetLoss, .bufferbloat, .ipFamilies], isBuiltIn: true)
    public static let fullDiagnostics = TestProfile(id: fixedID(4), name: "完整診斷", symbolName: "stethoscope",
                                                    items: Set(TestItem.allCases).subtracting([.continuousPing, .dropMonitor]), isBuiltIn: true)

    public static let builtIn: [TestProfile] = [quickSpeed, gaming, cellular, fullDiagnostics]
}
