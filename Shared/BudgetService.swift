import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 把 SwiftData 的資料換算成 BudgetSummary，並負責同步給 Widget。
enum BudgetService {

    static func currentSetting(in context: ModelContext) -> BudgetSetting {
        let descriptor = FetchDescriptor<BudgetSetting>()
        if let existing = try? context.fetch(descriptor), let first = existing.first {
            return first
        }
        let setting = BudgetSetting(monthlyBudget: 0)
        context.insert(setting)
        try? context.save()
        return setting
    }

    static func expenses(in context: ModelContext, from start: Date, to end: Date) -> [Expense] {
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func summary(in context: ModelContext, reference: Date = Date()) -> BudgetSummary {
        let setting = currentSetting(in: context)
        let interval = DateHelper.monthInterval(for: reference)
        let monthExpenses = expenses(in: context, from: interval.start, to: interval.end)
        let variableSpent = monthExpenses.reduce(0) { $0 + $1.amount }

        return BudgetSummary(
            monthlyBudget: setting.monthlyBudget,
            fixedTotal: setting.fixedExpenseTotal,
            variableSpent: variableSpent,
            daysInMonth: DateHelper.daysInMonth(for: reference),
            dayOfMonth: DateHelper.dayOfMonth(for: reference),
            updatedAt: Date()
        )
    }

    /// 每次寫入資料後呼叫：重算 → 寫入 App Group → 叫 Widget 更新。
    static func refreshWidgetSnapshot(context: ModelContext) {
        let summary = summary(in: context)
        BudgetSnapshotStore.save(summary)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// 每日累積花費（燒錢曲線用）
    static func cumulativeDailySpending(in context: ModelContext, reference: Date = Date()) -> [(day: Int, amount: Double)] {
        let interval = DateHelper.monthInterval(for: reference)
        let monthExpenses = expenses(in: context, from: interval.start, to: interval.end)
        let today = DateHelper.dayOfMonth(for: reference)
        var perDay: [Int: Double] = [:]
        for expense in monthExpenses {
            let day = DateHelper.dayOfMonth(for: expense.date)
            perDay[day, default: 0] += expense.amount
        }
        var running: Double = 0
        return (1...max(today, 1)).map { day in
            running += perDay[day] ?? 0
            return (day, running)
        }
    }
}
