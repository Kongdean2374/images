import Foundation

/// 主 App 算好後把結果寫進 App Group，Widget 直接讀，不用在 Widget 端跑 SwiftData 查詢。
enum BudgetSnapshotStore {
    private static let key = "widget.budgetSummary"

    static func save(_ summary: BudgetSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }

    static func load() -> BudgetSummary? {
        guard let data = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BudgetSummary.self, from: data)
    }
}
