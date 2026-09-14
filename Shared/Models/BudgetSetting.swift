import Foundation
import SwiftData

/// 預算設定（全 App 只會有一筆）。
@Model
final class BudgetSetting {
    var monthlyBudget: Double = 0
    var updatedAt: Date = Date()

    /// 是否把固定支出也算進「已花」的燒錢曲線裡（預設 true：一開月就先扣掉）
    var countsFixedExpensesUpfront: Bool = true

    @Relationship(deleteRule: .cascade, inverse: \FixedExpense.budget)
    var fixedExpenses: [FixedExpense]?

    init(monthlyBudget: Double = 0) {
        self.monthlyBudget = monthlyBudget
        self.updatedAt = Date()
        self.fixedExpenses = []
    }

    var sortedFixedExpenses: [FixedExpense] {
        (fixedExpenses ?? []).sorted { $0.dueDay < $1.dueDay }
    }

    var fixedExpenseTotal: Double {
        (fixedExpenses ?? []).reduce(0) { $0 + $1.amount }
    }

    /// 扣掉固定支出後，這個月真正能自由花的錢。
    var spendableBudget: Double {
        max(monthlyBudget - fixedExpenseTotal, 0)
    }
}

/// 每月固定支出（房租、保險…）
@Model
final class FixedExpense {
    var name: String = ""
    var amount: Double = 0
    var dueDay: Int = 1
    var createdAt: Date = Date()

    var budget: BudgetSetting?

    init(name: String, amount: Double, dueDay: Int = 1) {
        self.name = name
        self.amount = amount
        self.dueDay = min(max(dueDay, 1), 31)
        self.createdAt = Date()
    }
}
