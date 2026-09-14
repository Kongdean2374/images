import AppIntents
import SwiftData
import Foundation

/// 「嘿 Siri，記帳」→ 問金額 → 問分類 → 寫入（計劃書 §1-3，全程離線）
struct AddExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "記一筆帳"
    static var description = IntentDescription("用語音快速記錄一筆支出，資料只存在這台裝置。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "金額", requestValueDialog: "多少錢？")
    var amount: Double

    @Parameter(title: "分類", requestValueDialog: "哪個分類？")
    var category: CategoryEntity

    @Parameter(title: "備註")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("記一筆 \(\.$amount) 元的 \(\.$category)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppContainer.context
        DefaultData.seedIfNeeded(context: context)

        let matched = matchCategory(named: category.name, context: context)
            ?? DefaultData.fallbackCategory(context: context)

        let expense = Expense(
            amount: amount,
            date: Date(),
            category: matched,
            note: note,
            source: .siri
        )
        context.insert(expense)
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)

        let summary = BudgetService.summary(in: context)
        let dialog = IntentDialog(
            "已記下 \(Money.string(amount))，本月還可以花 \(Money.string(max(summary.remaining, 0)))。"
        )
        return .result(dialog: dialog)
    }

    @MainActor
    private func matchCategory(named name: String, context: ModelContext) -> SpendingCategory? {
        let descriptor = FetchDescriptor<SpendingCategory>(sortBy: [SortDescriptor(\.sortOrder)])
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { $0.fullName == name } ?? all.first { $0.name == name }
    }
}

/// 「還能花多少」
struct RemainingBudgetIntent: AppIntent {
    static var title: LocalizedStringResource = "還能花多少"
    static var description = IntentDescription("查詢本月剩餘可花額度。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppContainer.context
        let summary = BudgetService.summary(in: context)
        BudgetSnapshotStore.save(summary)

        guard summary.monthlyBudget > 0 else {
            return .result(dialog: IntentDialog("還沒設定月預算，先到 App 的預算設定頁設定一下。"))
        }
        let text = "本月還可以花 \(Money.string(max(summary.remaining, 0)))，距離月底還有 \(summary.daysRemaining) 天，平均每天 \(Money.string(summary.dailyAllowance))。"
        return .result(dialog: IntentDialog("\(text)"))
    }
}

/// 「開始記帳」→ 啟動動態島
struct StartLiveTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "開啟動態島記帳"
    static var description = IntentDescription("在動態島開一個記帳工作階段。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppContainer.context
        DefaultData.seedIfNeeded(context: context)
        let started = LiveActivityController.shared.start(context: context)
        return .result(dialog: IntentDialog(started ? "動態島記帳已開啟。" : "無法開啟動態島，請確認系統設定已允許即時動態。"))
    }
}

struct MoneyLeftShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddExpenseIntent(),
            phrases: [
                "用 \(.applicationName) 記帳",
                "\(.applicationName) 記一筆",
                "Add an expense in \(.applicationName)"
            ],
            shortTitle: "記一筆帳",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: RemainingBudgetIntent(),
            phrases: [
                "\(.applicationName) 還能花多少",
                "How much can I spend in \(.applicationName)"
            ],
            shortTitle: "還能花多少",
            systemImageName: "gauge.with.dots.needle.50percent"
        )
        AppShortcut(
            intent: StartLiveTrackingIntent(),
            phrases: [
                "\(.applicationName) 開始記帳",
                "Start tracking in \(.applicationName)"
            ],
            shortTitle: "開啟動態島記帳",
            systemImageName: "capsule.portrait"
        )
    }
}
