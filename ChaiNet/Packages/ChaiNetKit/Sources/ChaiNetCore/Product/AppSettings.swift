import Foundation

public enum ChartStyle: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case line, area, bar
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .line: "折線"
        case .area: "面積"
        case .bar: "長條"
        }
    }
}

public enum TestDurationSetting: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case auto, s5, s10, s15, s30
    public var id: String { rawValue }

    /// Fixed seconds, or `nil` for Auto.
    public var seconds: Double? {
        switch self {
        case .auto: nil
        case .s5: 5
        case .s10: 10
        case .s15: 15
        case .s30: 30
        }
    }

    public var displayName: String { seconds.map { "\(Int($0)) 秒" } ?? "自動" }
}

/// Auto duration: stop once throughput has stabilised.
///
/// After `minimumSeconds`, the test ends when the coefficient of variation of the last
/// `windowSamples` interval rates is below `targetCV` (steady state reached), or at
/// `maximumSeconds` at the latest.
public struct AutoDurationPolicy: Codable, Sendable, Hashable {
    public var minimumSeconds: Double = 6
    public var maximumSeconds: Double = 15
    public var windowSamples: Int = 20
    public var targetCV: Double = 0.10

    public init() {}

    public func shouldStop(elapsed: Double, recentMbps: [Double]) -> Bool {
        if elapsed >= maximumSeconds { return true }
        guard elapsed >= minimumSeconds, recentMbps.count >= windowSamples else { return false }
        guard let cv = Descriptive.coefficientOfVariation(Array(recentMbps.suffix(windowSamples))) else { return false }
        return cv < targetCV
    }
}

public enum ParallelConnectionsSetting: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case auto, one, two, four, eight, sixteen
    public var id: String { rawValue }
    public var fixedCount: Int? {
        switch self {
        case .auto: nil
        case .one: 1
        case .two: 2
        case .four: 4
        case .eight: 8
        case .sixteen: 16
        }
    }
    public var displayName: String { fixedCount.map { "\($0)" } ?? "自動（2–16）" }
}

public enum TrafficUsageSetting: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Full duration and payloads.
    case unlimited
    /// Halve durations on cellular and cap transfers.
    case saveOnCellular
    /// Cap every test at `maxMegabytes`.
    case capped
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .unlimited: "不限制"
        case .saveOnCellular: "行動網路節省模式"
        case .capped: "每次測試上限"
        }
    }
}

public enum ServerSelectionMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case automatic, manual
    public var id: String { rawValue }
    public var displayName: String { self == .automatic ? "自動（最低延遲）" : "手動指定" }
}

public enum DefaultTestMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case speedTest, customProfile, fullDiagnostics
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .speedTest: "一般測速"
        case .customProfile: "自訂測試組合"
        case .fullDiagnostics: "完整診斷"
        }
    }
}

public enum AppearanceSetting: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case dark, light, system
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .dark: "深色（預設）"
        case .light: "淺色"
        case .system: "跟隨系統"
        }
    }
}

public enum HistoryRetention: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case days30, days90, year1, forever
    public var id: String { rawValue }
    public var days: Int? {
        switch self {
        case .days30: 30
        case .days90: 90
        case .year1: 365
        case .forever: nil
        }
    }
    public var displayName: String { days.map { "\($0) 天" } ?? "永久保留" }
}

public enum DiagnosticDetailLevel: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Plain-language results; technical details collapsed.
    case simple
    /// Key statistics visible; raw data collapsed.
    case standard
    /// Everything expanded (engineers).
    case expert
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .simple: "簡易"
        case .standard: "標準"
        case .expert: "工程師"
        }
    }
}

public enum ExportFormatSetting: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case json, csv, text
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .json: "JSON（完整原始資料）"
        case .csv: "CSV（表格）"
        case .text: "純文字技術報告"
        }
    }
}

/// All user settings. Stored as one JSON blob so it can be versioned and unit tested.
public struct AppSettings: Codable, Sendable, Hashable {
    public var primarySpeedUnit: SpeedUnit = .auto
    public var secondarySpeedUnit: SpeedUnit? = .mBps
    public var chartStyle: ChartStyle = .area
    public var testDuration: TestDurationSetting = .auto
    public var trafficUsage: TrafficUsageSetting = .saveOnCellular
    public var maxMegabytesPerTest: Double = 500
    public var parallelConnections: ParallelConnectionsSetting = .auto
    public var ipPreference: IPFamilyPreference = .automatic
    public var serverSelection: ServerSelectionMode = .automatic
    public var manualServerID: String?
    public var customServers: [ServerDescriptor] = []
    public var defaultTestMode: DefaultTestMode = .speedTest
    public var defaultProfileID: UUID?
    public var appearance: AppearanceSetting = .dark
    public var historyRetention: HistoryRetention = .forever
    public var storeLocation: Bool = false
    public var includeLocationInExports: Bool = false
    public var autoCrossValidation: Bool = true
    public var backgroundChecks: Bool = false
    public var detailLevel: DiagnosticDetailLevel = .standard
    public var exportFormat: ExportFormatSetting = .json
    public var savedProfiles: [TestProfile] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case primarySpeedUnit, secondarySpeedUnit, chartStyle, testDuration, trafficUsage, maxMegabytesPerTest, parallelConnections, ipPreference, serverSelection, manualServerID, customServers, defaultTestMode, defaultProfileID, appearance, historyRetention, storeLocation, includeLocationInExports, autoCrossValidation, backgroundChecks, detailLevel, exportFormat, savedProfiles
    }

    /// Tolerant decoding: unknown / missing keys fall back to defaults so settings survive app updates.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(type(of: primarySpeedUnit), forKey: .primarySpeedUnit) { primarySpeedUnit = v }
        if c.contains(.secondarySpeedUnit) { secondarySpeedUnit = try? c.decode(SpeedUnit.self, forKey: .secondarySpeedUnit) }
        if let v = try? c.decodeIfPresent(type(of: chartStyle), forKey: .chartStyle) { chartStyle = v }
        if let v = try? c.decodeIfPresent(type(of: testDuration), forKey: .testDuration) { testDuration = v }
        if let v = try? c.decodeIfPresent(type(of: trafficUsage), forKey: .trafficUsage) { trafficUsage = v }
        if let v = try? c.decodeIfPresent(type(of: maxMegabytesPerTest), forKey: .maxMegabytesPerTest) { maxMegabytesPerTest = v }
        if let v = try? c.decodeIfPresent(type(of: parallelConnections), forKey: .parallelConnections) { parallelConnections = v }
        if let v = try? c.decodeIfPresent(type(of: ipPreference), forKey: .ipPreference) { ipPreference = v }
        if let v = try? c.decodeIfPresent(type(of: serverSelection), forKey: .serverSelection) { serverSelection = v }
        if c.contains(.manualServerID) { manualServerID = try? c.decode(String.self, forKey: .manualServerID) }
        if let v = try? c.decodeIfPresent(type(of: customServers), forKey: .customServers) { customServers = v }
        if let v = try? c.decodeIfPresent(type(of: defaultTestMode), forKey: .defaultTestMode) { defaultTestMode = v }
        if c.contains(.defaultProfileID) { defaultProfileID = try? c.decode(UUID.self, forKey: .defaultProfileID) }
        if let v = try? c.decodeIfPresent(type(of: appearance), forKey: .appearance) { appearance = v }
        if let v = try? c.decodeIfPresent(type(of: historyRetention), forKey: .historyRetention) { historyRetention = v }
        if let v = try? c.decodeIfPresent(type(of: storeLocation), forKey: .storeLocation) { storeLocation = v }
        if let v = try? c.decodeIfPresent(type(of: includeLocationInExports), forKey: .includeLocationInExports) { includeLocationInExports = v }
        if let v = try? c.decodeIfPresent(type(of: autoCrossValidation), forKey: .autoCrossValidation) { autoCrossValidation = v }
        if let v = try? c.decodeIfPresent(type(of: backgroundChecks), forKey: .backgroundChecks) { backgroundChecks = v }
        if let v = try? c.decodeIfPresent(type(of: detailLevel), forKey: .detailLevel) { detailLevel = v }
        if let v = try? c.decodeIfPresent(type(of: exportFormat), forKey: .exportFormat) { exportFormat = v }
        if let v = try? c.decodeIfPresent(type(of: savedProfiles), forKey: .savedProfiles) { savedProfiles = v }
    }

    /// Optionals are encoded as explicit `null` so "none" survives a round trip.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(primarySpeedUnit, forKey: .primarySpeedUnit)
        try c.encode(secondarySpeedUnit, forKey: .secondarySpeedUnit)
        try c.encode(chartStyle, forKey: .chartStyle)
        try c.encode(testDuration, forKey: .testDuration)
        try c.encode(trafficUsage, forKey: .trafficUsage)
        try c.encode(maxMegabytesPerTest, forKey: .maxMegabytesPerTest)
        try c.encode(parallelConnections, forKey: .parallelConnections)
        try c.encode(ipPreference, forKey: .ipPreference)
        try c.encode(serverSelection, forKey: .serverSelection)
        try c.encode(manualServerID, forKey: .manualServerID)
        try c.encode(customServers, forKey: .customServers)
        try c.encode(defaultTestMode, forKey: .defaultTestMode)
        try c.encode(defaultProfileID, forKey: .defaultProfileID)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(historyRetention, forKey: .historyRetention)
        try c.encode(storeLocation, forKey: .storeLocation)
        try c.encode(includeLocationInExports, forKey: .includeLocationInExports)
        try c.encode(autoCrossValidation, forKey: .autoCrossValidation)
        try c.encode(backgroundChecks, forKey: .backgroundChecks)
        try c.encode(detailLevel, forKey: .detailLevel)
        try c.encode(exportFormat, forKey: .exportFormat)
        try c.encode(savedProfiles, forKey: .savedProfiles)
    }

    /// Duration for one throughput direction, after traffic rules.
    ///
    ///     base = fixed setting, or AutoDurationPolicy.maximumSeconds for Auto
    ///     saveOnCellular on cellular → base / 2 (min 5 s)
    public func effectiveMaxDuration(onCellular: Bool) -> Double {
        let base = testDuration.seconds ?? AutoDurationPolicy().maximumSeconds
        if trafficUsage == .saveOnCellular && onCellular { return max(5, base / 2) }
        return base
    }

    /// Byte cap for one transfer direction, or nil if unlimited.
    public func transferByteCap(onCellular: Bool) -> Int64? {
        switch trafficUsage {
        case .unlimited: nil
        case .capped: Int64(maxMegabytesPerTest * 1_000_000)
        case .saveOnCellular: onCellular ? 150_000_000 : nil
        }
    }

    public var allProfiles: [TestProfile] { TestProfile.builtIn + savedProfiles }
}
