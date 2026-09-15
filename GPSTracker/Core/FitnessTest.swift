import Foundation

/// 體能測驗項目（營區常見的三項基本體能）
enum FitnessTestItem: String, Codable, CaseIterable, Identifiable {
    case sitUps
    case pushUps
    case run3000

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sitUps: return "2 分鐘仰臥起坐"
        case .pushUps: return "2 分鐘伏地挺身"
        case .run3000: return "3000 公尺跑走"
        }
    }

    var shortName: String {
        switch self {
        case .sitUps: return "仰臥起坐"
        case .pushUps: return "伏地挺身"
        case .run3000: return "3000 公尺"
        }
    }

    var systemImage: String {
        switch self {
        case .sitUps: return "figure.core.training"
        case .pushUps: return "figure.wrestling"
        case .run3000: return "figure.run"
        }
    }

    /// 計次項目的時限（秒）
    var timeLimit: TimeInterval? {
        self == .run3000 ? nil : 120
    }

    /// 成績越大越好（次數）還是越小越好（秒數）
    var higherIsBetter: Bool {
        self != .run3000
    }

    var unit: String {
        self == .run3000 ? "時間" : "次"
    }

    var met: Double {
        switch self {
        case .sitUps: return 6.0
        case .pushUps: return 7.0
        case .run3000: return 9.5
        }
    }
}

enum FitnessGrade: String, Codable, CaseIterable {
    case fail, pass, good, excellent, elite

    var displayName: String {
        switch self {
        case .fail: return "未達標"
        case .pass: return "及格"
        case .good: return "良"
        case .excellent: return "優"
        case .elite: return "特優"
        }
    }

    var order: Int {
        switch self {
        case .fail: return 0
        case .pass: return 1
        case .good: return 2
        case .excellent: return 3
        case .elite: return 4
        }
    }
}

/// 單一項目的門檻（次數，或秒數）
struct FitnessThresholds: Codable, Equatable {
    var pass: Double
    var good: Double
    var excellent: Double
    var elite: Double
}

/// 測驗標準。
///
/// 預設值是常見的公開參考值，不同單位、年齡組規定不同，
/// 使用者可以在設定頁自行改成自己單位的最新標準。
struct FitnessStandards: Codable, Equatable {
    var sitUps = FitnessThresholds(pass: 45, good: 55, excellent: 65, elite: 75)
    var pushUps = FitnessThresholds(pass: 42, good: 52, excellent: 62, elite: 72)
    /// 秒數，越小越好
    var run3000 = FitnessThresholds(pass: 930, good: 870, excellent: 810, elite: 750)

    func thresholds(for item: FitnessTestItem) -> FitnessThresholds {
        switch item {
        case .sitUps: return sitUps
        case .pushUps: return pushUps
        case .run3000: return run3000
        }
    }

    mutating func set(_ thresholds: FitnessThresholds, for item: FitnessTestItem) {
        switch item {
        case .sitUps: sitUps = thresholds
        case .pushUps: pushUps = thresholds
        case .run3000: run3000 = thresholds
        }
    }

    func grade(for item: FitnessTestItem, value: Double) -> FitnessGrade {
        let t = thresholds(for: item)
        if item.higherIsBetter {
            if value >= t.elite { return .elite }
            if value >= t.excellent { return .excellent }
            if value >= t.good { return .good }
            if value >= t.pass { return .pass }
            return .fail
        } else {
            if value <= t.elite { return .elite }
            if value <= t.excellent { return .excellent }
            if value <= t.good { return .good }
            if value <= t.pass { return .pass }
            return .fail
        }
    }

    /// 0...1 的達成度（相對於「特優」）
    func progress(for item: FitnessTestItem, value: Double) -> Double {
        let t = thresholds(for: item)
        if item.higherIsBetter {
            guard t.elite > 0 else { return 0 }
            return min(1, max(0, value / t.elite))
        } else {
            guard value > 0, t.elite > 0 else { return 0 }
            // 時間越短越好：以特優時間 / 實際時間 當達成度
            return min(1, max(0, t.elite / value))
        }
    }

    /// 距離下一級還差多少
    func gapToNext(for item: FitnessTestItem, value: Double) -> (grade: FitnessGrade, gap: Double)? {
        let t = thresholds(for: item)
        let ladder: [(FitnessGrade, Double)] = [(.pass, t.pass), (.good, t.good),
                                                (.excellent, t.excellent), (.elite, t.elite)]
        if item.higherIsBetter {
            for (grade, threshold) in ladder where value < threshold {
                return (grade, threshold - value)
            }
        } else {
            for (grade, threshold) in ladder where value > threshold {
                return (grade, value - threshold)
            }
        }
        return nil
    }
}

/// 標準的本地儲存
enum FitnessStandardsStore {
    private static let key = "fitnessStandards"

    static func load() -> FitnessStandards {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(FitnessStandards.self, from: data) else {
            return FitnessStandards()
        }
        return decoded
    }

    static func save(_ standards: FitnessStandards) {
        if let data = try? JSONEncoder().encode(standards) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
