import Foundation
import AppIntents
import SwiftData
#if canImport(ActivityKit)
import ActivityKit
#endif

/// 動態島上的按鈕都走這些 LiveActivityIntent，會在主 App 的 process 執行。
/// 這些檔案同時編進 App 與 Widget Extension，兩邊才對得起來。

#if canImport(ActivityKit)

@available(iOS 17.0, *)
enum LiveActivityMutator {

    static var current: Activity<ExpenseActivityAttributes>? {
        Activity<ExpenseActivityAttributes>.activities.first
    }

    static func update(_ transform: (inout ExpenseActivityAttributes.ContentState) -> Void) async {
        guard let activity = current else { return }
        var state = activity.content.state
        transform(&state)
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }
}

/// 加金額（+50 / +100 / +500…）
@available(iOS 17.0, *)
struct AdjustLiveAmountIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "調整金額"
    static var isDiscoverable: Bool = false

    @Parameter(title: "增減金額")
    var delta: Double

    init() {}
    init(delta: Double) { self.delta = delta }

    func perform() async throws -> some IntentResult {
        await LiveActivityMutator.update { state in
            state.amount = max(state.amount + delta, 0)
        }
        return .result()
    }
}

/// 歸零重來
@available(iOS 17.0, *)
struct ResetLiveAmountIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "清除金額"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await LiveActivityMutator.update { state in
            state.amount = 0
        }
        return .result()
    }
}

/// 切換快捷分類
@available(iOS 17.0, *)
struct SelectLiveCategoryIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "選擇分類"
    static var isDiscoverable: Bool = false

    @Parameter(title: "分類名稱") var categoryName: String
    @Parameter(title: "圖示") var iconName: String
    @Parameter(title: "顏色") var colorHex: String

    init() {}
    init(categoryName: String, iconName: String, colorHex: String) {
        self.categoryName = categoryName
        self.iconName = iconName
        self.colorHex = colorHex
    }

    func perform() async throws -> some IntentResult {
        await LiveActivityMutator.update { state in
            state.categoryName = categoryName
            state.categoryIcon = iconName
            state.categoryColorHex = colorHex
        }
        return .result()
    }
}

/// 送出：寫進 SwiftData，並把動態島狀態重置成下一筆
@available(iOS 17.0, *)
struct SaveLiveExpenseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "記下這筆"
    static var isDiscoverable: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let activity = LiveActivityMutator.current else { return .result() }
        let state = activity.content.state
        guard state.amount > 0 else { return .result() }

        let context = AppContainer.context
        let category = DefaultData.category(named: state.categoryName, context: context)
            ?? DefaultData.fallbackCategory(context: context)

        let expense = Expense(
            amount: state.amount,
            date: Date(),
            category: category,
            source: .liveActivity
        )
        context.insert(expense)
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
        let summary = BudgetService.summary(in: context)

        var newState = state
        newState.savedCount += 1
        newState.savedTotal += state.amount
        newState.lastSavedAmount = state.amount
        newState.remaining = summary.remaining
        newState.amount = 0
        await activity.update(ActivityContent(state: newState, staleDate: nil))
        return .result()
    }
}

/// 手動關閉動態島
@available(iOS 17.0, *)
struct EndLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "結束記帳"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        for activity in Activity<ExpenseActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

#endif
