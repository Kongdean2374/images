import Foundation
import SwiftUI

enum AchievementTier: Int, Comparable {
    case bronze = 0, silver, gold, platinum

    static func < (lhs: AchievementTier, rhs: AchievementTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .bronze: return "銅"
        case .silver: return "銀"
        case .gold: return "金"
        case .platinum: return "白金"
        }
    }

    var color: Color {
        switch self {
        case .bronze: return Color(red: 0.80, green: 0.55, blue: 0.35)
        case .silver: return Color(red: 0.75, green: 0.79, blue: 0.85)
        case .gold: return Color(red: 0.98, green: 0.78, blue: 0.32)
        case .platinum: return Color(red: 0.55, green: 0.90, blue: 0.95)
        }
    }
}

enum AchievementCategory: String, CaseIterable, Identifiable {
    case distance, endurance, consistency, strength, exploration, data

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .distance: return "里程"
        case .endurance: return "耐力"
        case .consistency: return "持續"
        case .strength: return "肌力"
        case .exploration: return "探索"
        case .data: return "資料"
        }
    }

    var icon: String {
        switch self {
        case .distance: return "map.fill"
        case .endurance: return "flame.fill"
        case .consistency: return "calendar"
        case .strength: return "figure.strengthtraining.functional"
        case .exploration: return "mountain.2.fill"
        case .data: return "chart.bar.fill"
        }
    }
}

struct Achievement: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let tier: AchievementTier
    let category: AchievementCategory
    let current: Double
    let goal: Double
    let unit: String

    var progress: Double {
        goal > 0 ? min(1, current / goal) : 0
    }

    var unlocked: Bool { current >= goal }

    var progressText: String {
        if unlocked { return "已達成" }
        if goal >= 1000 {
            return String(format: "%.0f / %.0f %@", current, goal, unit)
        }
        return String(format: "%.0f / %.0f %@", current, goal, unit)
    }
}

enum AchievementEngine {

    static func evaluate(sessions: [WorkoutSession], calendar: Calendar = .current) -> [Achievement] {
        guard !sessions.isEmpty else { return template() }

        let totalDistanceKM = sessions.reduce(0.0) { $0 + ($1.totalDistance ?? 0) } / 1000
        let longestKM = (sessions.compactMap { $0.totalDistance }.max() ?? 0) / 1000
        let longestMinutes = (sessions.map { $0.duration }.max() ?? 0) / 60
        let totalCount = Double(sessions.count)
        let totalElevation = sessions.reduce(0.0) { $0 + ($1.elevationGain ?? 0) }
        let totalFloors = Double(sessions.reduce(0) { $0 + ($1.floorsAscended ?? 0) })
        let records = StatsEngine.personalRecords(sessions: sessions, calendar: calendar)
        let streak = Double(max(records.currentStreak, records.longestStreak))
        let importedCount = Double(sessions.filter { $0.isImported }.count)
        let typesUsed = Double(Set(sessions.map { $0.type }).count)
        let earlyCount = Double(sessions.filter { calendar.component(.hour, from: $0.startDate) < 6 }.count)
        let nightCount = Double(sessions.filter { calendar.component(.hour, from: $0.startDate) >= 21 }.count)
        let plankBest = sessions.filter { $0.type == .plank }.map { $0.duration }.max() ?? 0
        let repsTotal = Double(sessions.reduce(0) { $0 + ($1.repCount ?? 0) })
        let testCount = Double(sessions.filter { $0.type == .fitnessTest }.count)
        let withRoute = Double(sessions.filter { !$0.routePoints.isEmpty }.count)
        let ratedCount = Double(sessions.filter { $0.rpe != nil }.count)

        var result: [Achievement] = []

        result += tiered(idPrefix: "distance", title: "累積里程", icon: "map.fill",
                         category: .distance, current: totalDistanceKM, unit: "km",
                         goals: [50, 250, 1000, 3000],
                         details: ["累積跑走 50 公里", "累積 250 公里", "累積 1000 公里", "累積 3000 公里"])

        result += tiered(idPrefix: "single", title: "單次距離", icon: "figure.run",
                         category: .endurance, current: longestKM, unit: "km",
                         goals: [5, 10, 21.1, 42.2],
                         details: ["單次跑滿 5 公里", "單次跑滿 10 公里", "單次達半馬距離", "單次達全馬距離"])

        result += tiered(idPrefix: "duration", title: "單次時長", icon: "clock.fill",
                         category: .endurance, current: longestMinutes, unit: "分",
                         goals: [30, 60, 120, 240],
                         details: ["連續運動 30 分鐘", "連續運動 1 小時", "連續運動 2 小時", "連續運動 4 小時"])

        result += tiered(idPrefix: "count", title: "運動次數", icon: "flame.fill",
                         category: .consistency, current: totalCount, unit: "次",
                         goals: [10, 50, 200, 500],
                         details: ["完成 10 次運動", "完成 50 次", "完成 200 次", "完成 500 次"])

        result += tiered(idPrefix: "streak", title: "連續天數", icon: "calendar.badge.clock",
                         category: .consistency, current: streak, unit: "天",
                         goals: [3, 7, 21, 60],
                         details: ["連續運動 3 天", "連續 7 天", "連續 21 天", "連續 60 天"])

        result += tiered(idPrefix: "elevation", title: "累積爬升", icon: "mountain.2.fill",
                         category: .exploration, current: totalElevation, unit: "m",
                         goals: [500, 3000, 10000, 30000],
                         details: ["累積爬升 500 公尺", "累積 3000 公尺", "累積 10000 公尺", "累積 30000 公尺"])

        result += tiered(idPrefix: "floors", title: "爬樓層數", icon: "figure.stair.stepper",
                         category: .exploration, current: totalFloors, unit: "層",
                         goals: [50, 300, 1000, 3000],
                         details: ["累積爬 50 層", "累積 300 層", "累積 1000 層", "累積 3000 層"])

        result += tiered(idPrefix: "reps", title: "累積次數", icon: "figure.jumprope",
                         category: .strength, current: repsTotal, unit: "下",
                         goals: [200, 1000, 5000, 20000],
                         details: ["原地運動累積 200 下", "累積 1000 下", "累積 5000 下", "累積 20000 下"])

        result += tiered(idPrefix: "plank", title: "棒式紀錄", icon: "figure.core.training",
                         category: .strength, current: plankBest, unit: "秒",
                         goals: [30, 60, 120, 300],
                         details: ["棒式撐滿 30 秒", "撐滿 1 分鐘", "撐滿 2 分鐘", "撐滿 5 分鐘"])

        result.append(Achievement(id: "early", title: "早鳥",
                                  detail: "清晨 6 點前開始運動 10 次",
                                  icon: "sunrise.fill", tier: .silver, category: .consistency,
                                  current: earlyCount, goal: 10, unit: "次"))
        result.append(Achievement(id: "night", title: "夜跑者",
                                  detail: "晚上 9 點後開始運動 10 次",
                                  icon: "moon.stars.fill", tier: .silver, category: .consistency,
                                  current: nightCount, goal: 10, unit: "次"))
        result.append(Achievement(id: "explorer", title: "全能玩家",
                                  detail: "體驗 8 種不同的運動模式",
                                  icon: "square.grid.3x3.fill", tier: .gold, category: .exploration,
                                  current: typesUsed, goal: 8, unit: "種"))
        result.append(Achievement(id: "tester", title: "體測常客",
                                  detail: "完成 5 次體能測驗",
                                  icon: "medal.fill", tier: .silver, category: .strength,
                                  current: testCount, goal: 5, unit: "次"))
        result.append(Achievement(id: "imported", title: "資料考古",
                                  detail: "從健康 App 匯入 100 筆歷史紀錄",
                                  icon: "square.and.arrow.down.fill", tier: .gold, category: .data,
                                  current: importedCount, goal: 100, unit: "筆"))
        result.append(Achievement(id: "routes", title: "軌跡收藏家",
                                  detail: "累積 25 筆含 GPS 軌跡的紀錄",
                                  icon: "point.topleft.down.curvedto.point.bottomright.up", tier: .gold,
                                  category: .data, current: withRoute, goal: 25, unit: "筆"))
        result.append(Achievement(id: "rated", title: "認真記錄",
                                  detail: "為 20 筆紀錄評自覺強度",
                                  icon: "hand.thumbsup.fill", tier: .bronze, category: .data,
                                  current: ratedCount, goal: 20, unit: "筆"))

        return result
    }

    private static func tiered(idPrefix: String,
                               title: String,
                               icon: String,
                               category: AchievementCategory,
                               current: Double,
                               unit: String,
                               goals: [Double],
                               details: [String]) -> [Achievement] {
        let tiers: [AchievementTier] = [.bronze, .silver, .gold, .platinum]
        // 防呆：目標數量若跟階層或說明對不上，不要直接越界崩潰
        return goals.enumerated().map { index, goal in
            let tier = tiers[min(index, tiers.count - 1)]
            let detail = index < details.count ? details[index] : ""
            return Achievement(id: "\(idPrefix)-\(index)",
                        title: "\(title)・\(tier.displayName)",
                        detail: detail,
                        icon: icon,
                        tier: tier,
                        category: category,
                        current: current,
                        goal: goal,
                        unit: unit)
        }
    }

    /// 尚無資料時的空白徽章牆
    private static func template() -> [Achievement] {
        evaluateEmpty()
    }

    private static func evaluateEmpty() -> [Achievement] {
        let empty: [WorkoutSession] = []
        guard empty.isEmpty else { return [] }
        // 用 0 進度產生同一份清單
        var result: [Achievement] = []
        result += tiered(idPrefix: "distance", title: "累積里程", icon: "map.fill",
                         category: .distance, current: 0, unit: "km",
                         goals: [50, 250, 1000, 3000],
                         details: ["累積跑走 50 公里", "累積 250 公里", "累積 1000 公里", "累積 3000 公里"])
        result += tiered(idPrefix: "count", title: "運動次數", icon: "flame.fill",
                         category: .consistency, current: 0, unit: "次",
                         goals: [10, 50, 200, 500],
                         details: ["完成 10 次運動", "完成 50 次", "完成 200 次", "完成 500 次"])
        return result
    }

    /// 只回傳每個系列中「下一個尚未解鎖」的徽章，避免牆面被同系列洗版
    static func highlights(_ achievements: [Achievement]) -> [Achievement] {
        var seen: Set<String> = []
        var result: [Achievement] = []
        for achievement in achievements.sorted(by: { $0.tier < $1.tier }) {
            let family = achievement.id.split(separator: "-").first.map(String.init) ?? achievement.id
            if achievement.unlocked { continue }
            if seen.contains(family) { continue }
            seen.insert(family)
            result.append(achievement)
        }
        return result.sorted { $0.progress > $1.progress }
    }
}
