import Foundation

/// Time budget of the Extreme Full Test ("完整測試（極限）"): every measurable item, maximum
/// load, with a user-chosen total duration distributed over the phases.
///
/// Allocation:
///
///     overhead  = fixed-cost items (server selection, DNS, HTTP/TLS/QUIC, MTU, traceroute) ≈ 71 s
///     budget    = max(total − overhead, 60 s)
///     phase_i   = max(floor_i, budget × weight_i)
///     server-dependent phases (ping, loss, download, upload) are shared by all servers:
///     per-server seconds = phase / serverCount   (never below the floor)
///
/// Weights: download 22 % · upload 22 % · monitoring 16 % · loss/jitter 14 % ·
/// cross-validation 8 % · idle ping 6 % · IPv4/IPv6 6 % · interface compare 6 %.
public struct FullTestPlan: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var key: String
        public var title: String
        public var seconds: Double
        /// true = time-budgeted; false = fixed-cost estimate.
        public var budgeted: Bool
        public var id: String { key }
    }

    public var requestedSeconds: Double
    public var serverCount: Int
    public var forceMaxStreams: Bool
    public var items: [Item]

    // Per-phase seconds (per server for server-dependent phases).
    public var idleSeconds: Double
    public var lossSeconds: Double
    public var throughputSeconds: Double
    public var monitoringSeconds: Double
    public var crossValidationSeconds: Double
    public var ipFamilySeconds: Double
    public var interfaceSeconds: Double

    public static let fixedOverhead: [(key: String, title: String, seconds: Double)] = [
        ("server", "伺服器選擇 / 健康檢查", 3), ("dns", "DNS 測試", 8), ("protocols", "HTTP / TLS / QUIC（多端點）", 15),
        ("mtu", "MTU", 15), ("traceroute", "路由追蹤", 30),
    ]
    public static let presets: [Double] = [60, 120, 300, 600]
    public static let minimumSeconds: Double = 60
    public static let maximumSeconds: Double = 1800

    public static func make(totalSeconds: Double, serverCount: Int = 1, forceMaxStreams: Bool = true) -> FullTestPlan {
        let total = min(max(totalSeconds, minimumSeconds), maximumSeconds)
        let servers = Double(max(1, serverCount))
        let overhead = fixedOverhead.reduce(0) { $0 + $1.seconds }
        let budget = max(total - overhead, 60)
        func share(_ w: Double, floor: Double) -> Double { max(floor, budget * w) }
        let idle = max(2, share(0.06, floor: 2) / servers)
        let loss = max(5, share(0.14, floor: 5) / servers)
        let throughput = max(6, share(0.22, floor: 6) / servers)
        let monitoring = share(0.16, floor: 10)
        let cross = share(0.08, floor: 3)
        let family = share(0.06, floor: 3)
        let interface = share(0.06, floor: 3)
        let n = servers
        var items: [Item] = [
            Item(key: "ping", title: "Ping（閒置延遲）× \(Int(n)) 台", seconds: idle * n, budgeted: true),
            Item(key: "loss", title: "封包遺失 / 抖動 / 連續遺失 / 突波 × \(Int(n)) 台", seconds: loss * n, budgeted: true),
            Item(key: "download", title: "下載 + 負載延遲 × \(Int(n)) 台", seconds: throughput * n, budgeted: true),
            Item(key: "upload", title: "上傳 + 負載延遲 × \(Int(n)) 台", seconds: throughput * n, budgeted: true),
            Item(key: "monitoring", title: "連續 Ping / 斷線監測", seconds: monitoring, budgeted: true),
            Item(key: "crossValidation", title: "多端點交叉驗證", seconds: cross, budgeted: true),
            Item(key: "ipFamilies", title: "IPv4 / IPv6 比較", seconds: family, budgeted: true),
            Item(key: "interfaceCompare", title: "Wi-Fi / 行動網路比較", seconds: interface, budgeted: true),
        ]
        items += fixedOverhead.map { Item(key: $0.key, title: $0.title, seconds: $0.seconds, budgeted: false) }
        return FullTestPlan(requestedSeconds: total, serverCount: Int(n), forceMaxStreams: forceMaxStreams, items: items,
                            idleSeconds: idle, lossSeconds: loss, throughputSeconds: throughput, monitoringSeconds: monitoring,
                            crossValidationSeconds: cross, ipFamilySeconds: family, interfaceSeconds: interface)
    }

    /// Estimated wall-clock time (fixed items are estimates; traceroute / MTU can vary).
    public var estimatedSeconds: Double { items.reduce(0) { $0 + $1.seconds } }

    /// Every measurable item.
    public static let allItems: Set<TestItem> = Set(TestItem.allCases)
}
