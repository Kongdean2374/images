import Foundation

/// Coarse access-network class used to group tests (Wi-Fi vs LTE vs 5G …).
public enum NetworkClass: String, Codable, Sendable, Hashable, CaseIterable {
    case wifi
    case wired
    case lte
    case nr
    case cellularOther
    case unknown

    public var isCellular: Bool { self == .lte || self == .nr || self == .cellularOther }
    public var isFixed: Bool { self == .wifi || self == .wired }

    public var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .wired: "有線網路"
        case .lte: "LTE"
        case .nr: "5G"
        case .cellularOther: "行動網路（2G/3G/未知制式）"
        case .unknown: "未知"
        }
    }

    public init(snapshot: NetworkSnapshot) {
        switch snapshot.primaryInterface {
        case .wifi: self = .wifi
        case .wiredEthernet: self = .wired
        case .cellular:
            switch snapshot.cellular?.radioTechnology.value {
            case .lte?: self = .lte
            case .nr?, .nrNSA?: self = .nr
            default: self = .cellularOther
            }
        default: self = .unknown
        }
    }
}

/// One test inside a diagnostic session (e.g. "Test A: 5G").
public struct SessionTest: Codable, Sendable, Hashable, Identifiable {
    public var label: String
    public var result: TestResult

    public var id: UUID { result.id }
    public var networkClass: NetworkClass { NetworkClass(snapshot: result.network) }

    public init(label: String, result: TestResult) {
        self.label = label
        self.result = result
    }
}

/// A diagnostic session groups several tests that are analysed *together*
/// (different networks, radio technologies, servers and IP families).
public struct DiagnosticSession: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var symptom: TroubleshootingSymptom?
    public var tests: [SessionTest]
    public var notes: [String]

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), symptom: TroubleshootingSymptom? = nil,
                tests: [SessionTest] = [], notes: [String] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.symptom = symptom
        self.tests = tests
        self.notes = notes
    }

    /// Next automatic label: "Test A", "Test B", …
    public var nextLabel: String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let index = tests.count
        return index < letters.count ? "Test \(letters[index])" : "Test \(index + 1)"
    }
}

/// Thresholds deciding whether a test is "degraded" for cross-test comparison.
///
/// A test is degraded when any measured metric crosses its limit:
///
///     loss > 2 %  ·  jitter > 30 ms  ·  idle latency median > 100 ms
///     download < 10 Mbps  ·  upload < 3 Mbps  ·  bufferbloat increase > 100 ms
///
/// Unmeasured metrics never make a test degraded.
public struct HealthThresholds: Codable, Sendable, Hashable {
    public var maxLossPercent = 2.0
    public var maxJitterMs = 30.0
    public var maxLatencyMs = 100.0
    public var minDownloadMbps = 10.0
    public var minUploadMbps = 3.0
    public var maxBloatMs = 100.0

    public init() {}
    public static let standard = HealthThresholds()
}

/// Health of one measurement. `notMeasured` covers "not tested" and "unavailable" (interface
/// down, probe impossible) — it is never counted as degraded.
public enum HealthStatus: String, Codable, Sendable, Hashable {
    case healthy, degraded, notMeasured
}

public struct TestHealthAssessment: Codable, Sendable, Hashable {
    public var measured: Bool
    public var isDegraded: Bool
    public var reasons: [String]
    /// Why nothing could be measured (unavailable interface, probe failure, not run).
    public var unavailableReason: String?

    public var status: HealthStatus { !measured ? .notMeasured : (isDegraded ? .degraded : .healthy) }

    public init(measured: Bool, isDegraded: Bool, reasons: [String], unavailableReason: String? = nil) {
        self.measured = measured
        self.isDegraded = isDegraded && measured
        self.reasons = measured ? reasons : []
        self.unavailableReason = unavailableReason
    }
}

public enum TestHealthEvaluator {
    public static func assess(_ result: TestResult, thresholds t: HealthThresholds = .standard) -> TestHealthAssessment {
        let m = result.metrics
        var reasons: [String] = []
        var measured = false
        func check(_ value: Double?, _ bad: (Double) -> Bool, _ text: (Double) -> String) {
            guard let value else { return }
            measured = true
            if bad(value) { reasons.append(text(value)) }
        }
        check(m.lossPercent, { $0 > t.maxLossPercent }) { "遺失 \(Fmt.d($0, 1))%" }
        check(m.jitterMs, { $0 > t.maxJitterMs }) { "抖動 \(Fmt.d($0, 0)) ms" }
        check(m.idleLatencyMs, { $0 > t.maxLatencyMs }) { "延遲 \(Fmt.d($0, 0)) ms" }
        check(m.downloadMbps, { $0 < t.minDownloadMbps }) { "下載 \(Fmt.d($0, 1)) Mbps" }
        check(m.uploadMbps, { $0 < t.minUploadMbps }) { "上傳 \(Fmt.d($0, 1)) Mbps" }
        check(m.downloadBloatMs, { $0 > t.maxBloatMs }) { "下載負載延遲 +\(Fmt.d($0, 0)) ms" }
        check(m.uploadBloatMs, { $0 > t.maxBloatMs }) { "上傳負載延遲 +\(Fmt.d($0, 0)) ms" }
        return TestHealthAssessment(measured: measured, isDegraded: !reasons.isEmpty, reasons: reasons,
                                    unavailableReason: measured ? nil : "此測試沒有可評估的指標")
    }

    /// Latency-only assessment (endpoint checks, per-interface probes).
    ///
    /// A probe that could not run at all (error, interface unavailable, zero replies) is
    /// **not measured** — it says nothing about quality and must not make a network "degraded".
    public static func assess(_ stats: LatencyStatistics?, error: String?, thresholds t: HealthThresholds = .standard) -> TestHealthAssessment {
        if let error { return TestHealthAssessment(measured: false, isDegraded: false, reasons: [], unavailableReason: error) }
        guard let stats, stats.sent > 0 else {
            return TestHealthAssessment(measured: false, isDegraded: false, reasons: [], unavailableReason: "未測試")
        }
        guard let rtt = stats.rtt else {
            return TestHealthAssessment(measured: false, isDegraded: false, reasons: [], unavailableReason: "沒有任何回應（無法區分無法連線與過濾）")
        }
        var reasons: [String] = []
        if stats.loss.lossPercent > t.maxLossPercent { reasons.append("遺失 \(Fmt.d(stats.loss.lossPercent, 1))%") }
        if rtt.median > t.maxLatencyMs { reasons.append("延遲 \(Fmt.d(rtt.median, 0)) ms") }
        if rtt.jitter > t.maxJitterMs { reasons.append("抖動 \(Fmt.d(rtt.jitter, 0)) ms") }
        return TestHealthAssessment(measured: true, isDegraded: !reasons.isEmpty, reasons: reasons)
    }
}

/// Number formatting shared by diagnostics text (locale-independent, "." decimal separator).
public enum Fmt {
    public static func d(_ v: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", v) }
}
