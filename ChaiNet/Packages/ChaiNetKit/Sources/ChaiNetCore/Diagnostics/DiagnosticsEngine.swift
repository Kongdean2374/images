import Foundation

public enum DiagnosticSeverity: String, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case info, warning, critical

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .info: "資訊"
        case .warning: "警告"
        case .critical: "嚴重"
        }
    }
}

/// Stable identifiers for findings (used in tests, exports and analytics-free history filters).
public enum DiagnosticCode: String, Codable, Sendable, Hashable, CaseIterable {
    case uplinkCongestion
    case asymmetricLink
    case lowLatencyHighJitter
    case highJitter
    case severePacketLoss
    case moderatePacketLoss
    case burstLoss
    case downloadBufferbloat
    case uploadBufferbloat
    case highLatency
    case unstableDownload
    case unstableUpload
    case lowDownload
    case slowSystemDNS
    case dnsHighTailLatency
    case ipv6Unavailable
    case vpnActive
    case lowDataMode
    case expensiveNetwork
    case latencySpikes
    case networkDrops
    /// Legacy (≤ v2.2.0): decoded, never produced — replaced by the two scoped codes below.
    case http3Unavailable
    /// One endpoint's strict HTTP/3 attempt fell back to TCP (endpoint-specific, info only).
    case http3FallbackObserved
    /// Every one of ≥ 2 independent strict HTTP/3 endpoints failed.
    case generalHttp3Unavailable
    case slowTLS
    case reducedMTU
    case healthy
}

public struct DiagnosticFinding: Codable, Sendable, Hashable, Identifiable {
    public var code: DiagnosticCode
    public var severity: DiagnosticSeverity
    public var title: String
    public var detail: String
    public var recommendation: String
    public var id: DiagnosticCode { code }

    public init(code: DiagnosticCode, severity: DiagnosticSeverity, title: String, detail: String, recommendation: String) {
        self.code = code
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
    }
}

/// A single diagnostic rule. Rules are small, independent and individually testable.
public protocol DiagnosticRule: Sendable {
    var code: DiagnosticCode { get }
    func evaluate(_ m: MetricSnapshot) -> DiagnosticFinding?
}

public protocol DiagnosticsEngineProtocol: Sendable {
    func diagnose(_ metrics: MetricSnapshot) -> [DiagnosticFinding]
}

/// Rule-based diagnostics. Findings are sorted by severity (critical first). When nothing is
/// wrong and enough data exists, a single `.healthy` finding is returned.
public struct DiagnosticsEngine: DiagnosticsEngineProtocol {
    public var rules: [any DiagnosticRule]

    public init(rules: [any DiagnosticRule] = DiagnosticRules.all) {
        self.rules = rules
    }

    public func diagnose(_ metrics: MetricSnapshot) -> [DiagnosticFinding] {
        var findings = rules.compactMap { $0.evaluate(metrics) }
        // A more specific finding suppresses its generic counterpart.
        let codes = Set(findings.map(\.code))
        if codes.contains(.lowLatencyHighJitter) { findings.removeAll { $0.code == .highJitter } }
        if codes.contains(.severePacketLoss) { findings.removeAll { $0.code == .moderatePacketLoss } }

        let hasCoreData = metrics.downloadMbps != nil || metrics.idleLatencyMs != nil
        if hasCoreData, !findings.contains(where: { $0.severity >= .warning }) {
            findings.append(DiagnosticFinding(code: .healthy, severity: .info, title: "連線狀況良好",
                                              detail: "未偵測到明顯的網路異常。",
                                              recommendation: "無需處理。"))
        }
        return findings.sorted { lhs, rhs in
            lhs.severity != rhs.severity ? lhs.severity > rhs.severity : lhs.code.rawValue < rhs.code.rawValue
        }
    }
}

/// A rule built from a closure — keeps the rule list compact while each rule stays testable
/// through `DiagnosticsEngine(rules: [DiagnosticRules.x])`.
public struct ClosureRule: DiagnosticRule {
    public let code: DiagnosticCode
    let body: @Sendable (MetricSnapshot) -> DiagnosticFinding?

    public init(_ code: DiagnosticCode, _ body: @escaping @Sendable (MetricSnapshot) -> DiagnosticFinding?) {
        self.code = code
        self.body = body
    }

    public func evaluate(_ m: MetricSnapshot) -> DiagnosticFinding? { body(m) }
}
