import Foundation
import SwiftData

/// 在兩個資料庫之間整包複製（舊 iCloud 資料搬遷、備份還原都用這個）。
enum StoreCopier {

    @discardableResult
    static func copyIfDestinationEmpty(from source: ModelContext, to target: ModelContext) -> Int {
        let existingExpenses = (try? target.fetchCount(FetchDescriptor<Expense>())) ?? 0
        guard existingExpenses == 0 else { return 0 }

        // 目的地可能只有預設分類 → 清掉再整包複製，維持乾淨對應
        let categories = (try? target.fetch(FetchDescriptor<SpendingCategory>())) ?? []
        for category in categories { target.delete(category) }
        let tags = (try? target.fetch(FetchDescriptor<EmotionTag>())) ?? []
        for tag in tags { target.delete(tag) }
        try? target.save()

        return copy(from: source, to: target)
    }

    @discardableResult
    static func copy(from source: ModelContext, to target: ModelContext) -> Int {
        var categoryMap: [PersistentIdentifier: SpendingCategory] = [:]
        let categories = (try? source.fetch(
            FetchDescriptor<SpendingCategory>(sortBy: [SortDescriptor(\.sortOrder)])
        )) ?? []

        for category in categories where category.parent == nil {
            let copy = SpendingCategory(
                name: category.name, iconName: category.iconName, colorHex: category.colorHex,
                isDefault: category.isDefault, sortOrder: category.sortOrder
            )
            target.insert(copy)
            categoryMap[category.persistentModelID] = copy
        }
        for category in categories where category.parent != nil {
            let parentCopy = category.parent.flatMap { categoryMap[$0.persistentModelID] }
            let copy = SpendingCategory(
                name: category.name, iconName: category.iconName, colorHex: category.colorHex,
                isDefault: category.isDefault, sortOrder: category.sortOrder, parent: parentCopy
            )
            target.insert(copy)
            categoryMap[category.persistentModelID] = copy
        }

        var tagMap: [PersistentIdentifier: EmotionTag] = [:]
        let tags = (try? source.fetch(FetchDescriptor<EmotionTag>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        for tag in tags {
            let copy = EmotionTag(
                name: tag.name, iconName: tag.iconName, colorHex: tag.colorHex,
                isBuiltIn: tag.isBuiltIn, sortOrder: tag.sortOrder
            )
            target.insert(copy)
            tagMap[tag.persistentModelID] = copy
        }

        if let setting = (try? source.fetch(FetchDescriptor<BudgetSetting>()))?.first {
            let existing = (try? target.fetch(FetchDescriptor<BudgetSetting>()))?.first
            let targetSetting = existing ?? BudgetSetting(monthlyBudget: setting.monthlyBudget)
            targetSetting.monthlyBudget = setting.monthlyBudget
            if existing == nil { target.insert(targetSetting) }
            for fixed in setting.sortedFixedExpenses {
                let copy = FixedExpense(name: fixed.name, amount: fixed.amount, dueDay: fixed.dueDay)
                copy.budget = targetSetting
                target.insert(copy)
            }
        }

        var copied = 0
        let expenses = (try? source.fetch(FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date)]))) ?? []
        for expense in expenses {
            let copy = Expense(
                amount: expense.amount,
                date: expense.date,
                category: expense.category.flatMap { categoryMap[$0.persistentModelID] },
                note: expense.note,
                emotionTag: expense.emotionTag.flatMap { tagMap[$0.persistentModelID] },
                source: expense.source,
                merchant: expense.merchant,
                receiptImageData: expense.receiptImageData
            )
            target.insert(copy)
            copied += 1
        }

        try? target.save()
        return copied
    }
}
