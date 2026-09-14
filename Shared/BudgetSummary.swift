import Foundation

/// 首頁與 Widget 共用的「本月狀態」計算結果。
struct BudgetSummary: Codable, Equatable {
    var monthlyBudget: Double = 0
    var fixedTotal: Double = 0
    var variableSpent: Double = 0
    var daysInMonth: Int = 30
    var dayOfMonth: Int = 1
    var updatedAt: Date = Date()

    /// 本月剩餘可花額度 = 月預算 − 固定支出 − 已記錄變動支出
    var remaining: Double { monthlyBudget - fixedTotal - variableSpent }

    /// 扣掉固定支出後的可自由支配預算
    var spendable: Double { max(monthlyBudget - fixedTotal, 0) }

    /// 距離月底還有幾天（含今天）
    var daysRemaining: Int { max(daysInMonth - dayOfMonth + 1, 1) }

    /// 平均每天還可以花多少
    var dailyAllowance: Double { max(remaining, 0) / Double(daysRemaining) }

    /// 理想花費速度（每日）
    var idealDailyPace: Double { daysInMonth > 0 ? spendable / Double(daysInMonth) : 0 }

    /// 到今天為止「應該」花掉的金額
    var idealSpentToDate: Double { idealDailyPace * Double(dayOfMonth) }

    /// 實際花費速度（每日）
    var actualDailyPace: Double { dayOfMonth > 0 ? variableSpent / Double(dayOfMonth) : 0 }

    /// 燒錢速度比：1.0 = 剛好照計劃，>1 = 超速
    var burnRatio: Double {
        guard idealDailyPace > 0 else { return variableSpent > 0 ? 2 : 0 }
        return actualDailyPace / idealDailyPace
    }

    var burnLevel: BurnLevel {
        switch burnRatio {
        case ..<0.9: return .good
        case 0.9..<1.05: return .warning
        default: return .over
        }
    }

    /// 照目前速度，這個月預計會花掉多少
    var projectedMonthTotal: Double { actualDailyPace * Double(daysInMonth) }

    /// 照目前速度，預算可以撐到第幾天（超支時才有意義）
    var projectedRunOutDay: Int? {
        guard actualDailyPace > 0 else { return nil }
        let day = Int((spendable / actualDailyPace).rounded(.down))
        return day < daysInMonth ? max(day, 1) : nil
    }

    static let placeholder = BudgetSummary(
        monthlyBudget: 20000, fixedTotal: 5000, variableSpent: 6200,
        daysInMonth: 30, dayOfMonth: 12
    )
}

enum BurnLevel: String, Codable {
    case good, warning, over

    var label: String {
        switch self {
        case .good: return "速度健康"
        case .warning: return "接近臨界"
        case .over: return "花太快了"
        }
    }
}
