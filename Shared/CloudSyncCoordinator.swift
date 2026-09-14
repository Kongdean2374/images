import Foundation
import SwiftData

/// 在兩個資料庫檔之間搬資料（切換 iCloud 同步時用，避免資料「不見」）。
enum StoreCopier {

    /// 只有在目的地是空的時候才複製，避免重複匯入。
    @discardableResult
    static func copyIfDestinationEmpty(from source: ModelContext, to target: ModelContext) -> Int {
        let existingExpenses = (try? target.fetchCount(FetchDescriptor<Expense>())) ?? 0
        let existingCategories = (try? target.fetchCount(FetchDescriptor<SpendingCategory>())) ?? 0
        guard existingExpenses == 0 else { return 0 }
        // 目的地只有預設分類、沒有任何紀錄 → 清掉再整包複製，維持乾淨對應
        if existingCategories > 0 {
            let categories = (try? target.fetch(FetchDescriptor<SpendingCategory>())) ?? []
            for category in categories { target.delete(category) }
            let tags = (try? target.fetch(FetchDescriptor<EmotionTag>())) ?? []
            for tag in tags { target.delete(tag) }
            try? target.save()
        }
        return copy(from: source, to: target)
    }

    @discardableResult
    static func copy(from source: ModelContext, to target: ModelContext) -> Int {
        var categoryMap: [PersistentIdentifier: SpendingCategory] = [:]

        let categories = (try? source.fetch(
            FetchDescriptor<SpendingCategory>(sortBy: [SortDescriptor(\.sortOrder)])
        )) ?? []

        // 先父後子，子分類才對得到 parent
        for category in categories where category.parent == nil {
            let copy = SpendingCategory(
                name: category.name,
                iconName: category.iconName,
                colorHex: category.colorHex,
                isDefault: category.isDefault,
                sortOrder: category.sortOrder
            )
            target.insert(copy)
            categoryMap[category.persistentModelID] = copy
        }
        for category in categories where category.parent != nil {
            let parentCopy = category.parent.flatMap { categoryMap[$0.persistentModelID] }
            let copy = SpendingCategory(
                name: category.name,
                iconName: category.iconName,
                colorHex: category.colorHex,
                isDefault: category.isDefault,
                sortOrder: category.sortOrder,
                parent: parentCopy
            )
            target.insert(copy)
            categoryMap[category.persistentModelID] = copy
        }

        var tagMap: [PersistentIdentifier: EmotionTag] = [:]
        let tags = (try? source.fetch(FetchDescriptor<EmotionTag>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        for tag in tags {
            let copy = EmotionTag(
                name: tag.name,
                iconName: tag.iconName,
                colorHex: tag.colorHex,
                isBuiltIn: tag.isBuiltIn,
                sortOrder: tag.sortOrder
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

/// 設定頁的 iCloud 開關實際做的事。
/// 重點：切換時「當場」就把容器建起來試一次，成功才寫設定；
/// 這樣萬一要閃退，是在使用者按下開關的當下，而不是下次啟動時莫名其妙開不了。
enum CloudSyncCoordinator {

    struct Result {
        var success: Bool
        var message: String
    }

    /// 開啟 iCloud 同步：建 CloudKit 容器 → 把本機資料複製過去 → 寫設定
    static func enable(currentContainer: ModelContainer) -> Result {
        guard Persistence.iCloudAccountAvailable else {
            let note = "這台裝置沒有可用的 iCloud 帳號，或這份簽名沒有 iCloud 權限（免費 Apple ID 自簽就會這樣）。已維持本機模式，資料完全不受影響。"
            AppSettings.cloudFailureNote = note
            AppSettings.cloudSyncEnabled = false
            return Result(success: false, message: note)
        }

        guard let cloudContainer = Persistence.makeCloudContainer() else {
            AppSettings.cloudSyncEnabled = false
            let note = AppSettings.cloudFailureNote ?? "無法建立 iCloud 資料容器，已維持本機模式。"
            return Result(success: false, message: note)
        }

        let copied = StoreCopier.copyIfDestinationEmpty(
            from: ModelContext(currentContainer),
            to: ModelContext(cloudContainer)
        )
        AppSettings.cloudSyncEnabled = true
        AppSettings.cloudFailureNote = nil
        return Result(
            success: true,
            message: copied > 0
                ? "已開啟 iCloud 同步，並把 \(copied) 筆紀錄複製過去。請完全關閉 App 再重新開啟。"
                : "已開啟 iCloud 同步。請完全關閉 App 再重新開啟。"
        )
    }

    /// 關閉 iCloud 同步：把目前（雲端）資料複製回本機檔 → 寫設定
    static func disable(currentContainer: ModelContainer) -> Result {
        AppSettings.cloudSyncEnabled = false
        AppSettings.cloudFailureNote = nil

        guard Persistence.status == .cloud, let localContainer = Persistence.makeLocalContainer() else {
            return Result(success: true, message: "已關閉 iCloud 同步，資料只會留在這台裝置。")
        }
        let copied = StoreCopier.copyIfDestinationEmpty(
            from: ModelContext(currentContainer),
            to: ModelContext(localContainer)
        )
        return Result(
            success: true,
            message: copied > 0
                ? "已關閉 iCloud 同步，並把 \(copied) 筆紀錄複製回本機。請完全關閉 App 再重新開啟。"
                : "已關閉 iCloud 同步。請完全關閉 App 再重新開啟。"
        )
    }
}
