import Foundation

/// 一筆可用來推算步幅的樣本
struct StrideSample: Identifiable, Hashable {
    enum Source: String, Codable, Hashable {
        case health          // 健康 App 的歷史資料
        case healthWorkout   // 健康 App 的體能訓練
        case gpsSession      // 本 App 自己的 GPS 紀錄
        case manual          // 手動輸入（如跑步機實際距離）

        var displayName: String {
            switch self {
            case .health: return "健康 App 每日資料"
            case .healthWorkout: return "健康 App 體能訓練"
            case .gpsSession: return "App 內 GPS 紀錄"
            case .manual: return "手動校正"
            }
        }
    }

    let id = UUID()
    let stride: Double      // 公尺 / 步
    let distance: Double    // 公尺
    let steps: Int
    let date: Date
    let source: Source
    let profile: StrideProfile

    var ageDays: Double {
        max(0, Date().timeIntervalSince(date) / 86400)
    }

    /// 越近期越可信（半衰期一年）；距離越長越可信
    var weight: Double {
        let recency = pow(0.5, ageDays / 365.0)
        let length = min(1.0, distance / 3000.0)
        let sourceWeight: Double
        switch source {
        case .gpsSession, .manual: sourceWeight = 1.0
        case .healthWorkout: sourceWeight = 0.95
        case .health: sourceWeight = 0.75
        }
        return recency * max(0.25, length) * sourceWeight
    }
}

/// 一次校正的結果與可信度
struct CalibrationResult {
    var profile: StrideProfile
    var stride: Double
    /// 0...1
    var confidence: Double
    var rawSampleCount: Int
    var weightedSampleCount: Double
    var consistency: Double
    var recencyScore: Double
    var coverageScore: Double
    var coefficientOfVariation: Double
    var spanDays: Int
    var newestDate: Date?
    var oldestDate: Date?
    var sourceBreakdown: [StrideSample.Source: Int]

    var confidencePercent: Int { Int((confidence * 100).rounded()) }

    var grade: String {
        switch confidence {
        case ..<0.25: return "資料不足"
        case ..<0.5: return "粗略"
        case ..<0.75: return "堪用"
        case ..<0.9: return "良好"
        default: return "資料充分"
        }
    }

    /// 還需要什麼才能更準
    var advice: String {
        if rawSampleCount == 0 {
            return "還沒有可用的資料。授權健康 App 或先用 GPS 模式跑一次，就能開始校正。"
        }
        var items: [String] = []
        if coverageScore < 0.75 {
            let need = max(1, Int(ceil((6.0 - weightedSampleCount))))
            items.append("再累積約 \(need) 次有距離與步數的運動")
        }
        if consistency < 0.6 {
            items.append(String(format: "資料波動偏大（變異 %.0f%%），多幾次穩定配速的紀錄會更準", coefficientOfVariation * 100))
        }
        if recencyScore < 0.6 {
            items.append("最近一次可用資料距今較久，近期再跑一次會讓數值貼近現況")
        }
        if items.isEmpty {
            return "資料量與一致性都足夠，仍需獨立場次驗證距離誤差。"
        }
        return "建議：" + items.joined(separator: "；") + "。"
    }
}

/// 持久化的校正狀態
struct StrideState: Codable {
    var stride: Double
    var confidence: Double
    var sampleCount: Int
    var weightedCount: Double
    var spanDays: Int
    var updated: Date
    var method: String      // auto / learn / manual
    var modelVersion: Int?
    var validation: ValidationOutcome?
}

/// 個人步幅校正。
///
/// 三個來源：
/// 1. 自動計算：一次抓健康 App 的歷史資料（可回溯數年）
/// 2. 逐次學習：每做完一次 GPS 運動就用該次資料微調
/// 3. 手動：跑步機輸入實際距離反推
enum StrideCalibration {

    private static let defaults = UserDefaults.standard

    private static func stateKey(_ profile: StrideProfile) -> String { "strideState.\(profile.rawValue)" }

    static func defaultStride(_ profile: StrideProfile) -> Double {
        profile == .running ? 1.05 : 0.72
    }

    static func state(_ profile: StrideProfile) -> StrideState? {
        guard let data = defaults.data(forKey: stateKey(profile)),
              let decoded = try? JSONDecoder().decode(StrideState.self, from: data) else { return nil }
        return decoded
    }

    private static func save(_ state: StrideState, profile: StrideProfile) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: stateKey(profile))
        }
    }

    static func stride(_ profile: StrideProfile) -> Double {
        let value = (state(profile) ?? (profile == .ruck ? state(.walking) : nil))?.stride ?? 0
        return value > 0.2 ? value : defaultStride(profile)
    }

    static func confidence(_ profile: StrideProfile) -> Double {
        state(profile)?.confidence ?? 0
    }

    static func sampleCount(_ profile: StrideProfile) -> Int {
        state(profile)?.sampleCount ?? 0
    }

    static func lastUpdated(_ profile: StrideProfile) -> Date? {
        state(profile)?.updated
    }

    static func method(_ profile: StrideProfile) -> String {
        state(profile)?.method ?? ""
    }

    static func isCalibrated(_ profile: StrideProfile) -> Bool {
        (state(profile)?.sampleCount ?? 0) > 0
    }

    static func distance(steps: Int, profile: StrideProfile) -> Double {
        Double(steps) * stride(profile)
    }

    /// Only independent holdout improvements may replace a model. Old snapshots stay intact.
    static func applyValidated(_ outcome: ValidationOutcome, profile: StrideProfile) {
        guard outcome.applied, let stride = outcome.candidateStride, outcome.testCount >= 2 else { return }
        snapshot(profile)
        save(StrideState(stride: stride, confidence: min(1, Double(outcome.sampleIDs.count) / 12),
                         sampleCount: outcome.sampleIDs.count, weightedCount: Double(outcome.sampleIDs.count),
                         spanDays: 0, updated: Date(), method: "validated", modelVersion: (state(profile)?.modelVersion ?? 0) + 1,
                         validation: outcome), profile: profile)
    }

    static func snapshot(_ profile: StrideProfile) {
        let current = defaults.data(forKey: stateKey(profile)) ?? (try? JSONEncoder().encode(StrideState(stride: defaultStride(profile), confidence: 0, sampleCount: 0, weightedCount: 0, spanDays: 0, updated: Date(), method: "default")))
        if let data = current { defaults.set(data, forKey: stateKey(profile) + ".previous") }
    }
    static func rollback(_ profile: StrideProfile) {
        let previousKey = stateKey(profile) + ".previous"
        guard let previous = defaults.data(forKey: previousKey) else { return }
        let current = defaults.data(forKey: stateKey(profile))
        defaults.set(previous, forKey: stateKey(profile))
        if let current { defaults.set(current, forKey: previousKey) }
    }
    static func previous(_ profile: StrideProfile) -> StrideState? {
        guard let data = defaults.data(forKey: stateKey(profile) + ".previous") else { return nil }
        return try? JSONDecoder().decode(StrideState.self, from: data)
    }
    static func restorePrevious(_ state: StrideState, profile: StrideProfile) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey(profile) + ".previous") }
    }

    /// 直接設定（設定頁手動微調）
    static func setManual(_ value: Double, profile: StrideProfile) {
        guard value.isFinite, value > 0.25, value <= (profile == .running ? 2.8 : 1.5) else { return }
        snapshot(profile)
        let existing = state(profile)
        save(StrideState(stride: value,
                         confidence: max(0.4, existing?.confidence ?? 0.4),
                         sampleCount: max(1, existing?.sampleCount ?? 1),
                         weightedCount: existing?.weightedCount ?? 1,
                         spanDays: existing?.spanDays ?? 0,
                         updated: Date(),
                         method: "manual"),
             profile: profile)
    }

    /// 從備份還原校正狀態
    static func restore(_ state: StrideState, profile: StrideProfile) {
        snapshot(profile)
        save(state, profile: profile)
    }

    static func reset(_ profile: StrideProfile) {
        snapshot(profile)
        defaults.removeObject(forKey: stateKey(profile))
    }
}
