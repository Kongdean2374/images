import Foundation
import AppIntents
import SwiftData

/// 主畫面小工具上的「+50 / +100」按鈕。按下去就直接記一筆到預設分類，
/// 事後可以在明細頁改分類。按鈕本身就是使用者的確認動作。
@available(iOS 17.0, *)
struct QuickAddExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "快速記一筆"
    static var description = IntentDescription("在主畫面小工具上直接記一筆固定金額的支出。")
    static var isDiscoverable: Bool = false

    @Parameter(title: "金額")
    var amount: Double

    init() {}
    init(amount: Double) { self.amount = amount }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard amount > 0 else { return .result() }
        let context = AppContainer.context
        DefaultData.seedIfNeeded(context: context)

        let expense = Expense(
            amount: amount,
            date: Date(),
            category: DefaultData.fallbackCategory(context: context),
            source: .manual
        )
        context.insert(expense)
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
        return .result()
    }
}
