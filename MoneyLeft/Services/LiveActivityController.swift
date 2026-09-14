import Foundation
import SwiftData
#if canImport(ActivityKit)
import ActivityKit
#endif

/// 負責啟動／更新／關閉「記帳中」的 Live Activity（計劃書 §1-2）。
@MainActor
final class LiveActivityController: ObservableObject {
    static let shared = LiveActivityController()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var lastError: String?

    private init() {
        refreshState()
    }

    var activitiesEnabled: Bool {
        #if canImport(ActivityKit)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    func refreshState() {
        #if canImport(ActivityKit)
        isActive = !Activity<ExpenseActivityAttributes>.activities.isEmpty
        #endif
    }

    @discardableResult
    func start(context: ModelContext) -> Bool {
        #if canImport(ActivityKit)
        guard activitiesEnabled else {
            lastError = "系統尚未允許「即時動態」，請到 設定 → MoneyLeft 開啟。"
            return false
        }
        guard Activity<ExpenseActivityAttributes>.activities.isEmpty else {
            isActive = true
            return true
        }

        let summary = BudgetService.summary(in: context)
        let quickCategories = topCategories(context: context)
        let hours = AppSettings.liveActivityAutoCloseHours
        let autoCloseAt = hours > 0 ? Date().addingTimeInterval(TimeInterval(hours) * 3600) : nil

        let attributes = ExpenseActivityAttributes(
            startedAt: Date(),
            quickAmounts: AppSettings.quickAmounts.prefix(3).map { $0 },
            quickCategories: quickCategories
        )
        let first = quickCategories.first
        let state = ExpenseActivityAttributes.ContentState(
            amount: 0,
            categoryName: first?.name ?? "其他",
            categoryIcon: first?.iconName ?? "ellipsis.circle.fill",
            categoryColorHex: first?.colorHex ?? "#8E8E93",
            savedCount: 0,
            savedTotal: 0,
            lastSavedAmount: nil,
            remaining: summary.remaining,
            autoCloseAt: autoCloseAt
        )

        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: autoCloseAt),
                pushType: nil
            )
            isActive = true
            lastError = nil
            scheduleAutoCloseIfNeeded(at: autoCloseAt)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
        #else
        return false
        #endif
    }

    func end() {
        #if canImport(ActivityKit)
        Task {
            for activity in Activity<ExpenseActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await MainActor.run { self.isActive = false }
        }
        #endif
    }

    /// App 回到前景時：同步剩餘額度，並處理已過期的自動關閉時間。
    func syncOnForeground(context: ModelContext) {
        #if canImport(ActivityKit)
        let summary = BudgetService.summary(in: context)
        Task {
            for activity in Activity<ExpenseActivityAttributes>.activities {
                var state = activity.content.state
                if let closeAt = state.autoCloseAt, closeAt <= Date() {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    continue
                }
                state.remaining = summary.remaining
                await activity.update(ActivityContent(state: state, staleDate: state.autoCloseAt))
            }
            await MainActor.run { self.refreshState() }
        }
        #endif
    }

    private func scheduleAutoCloseIfNeeded(at date: Date?) {
        #if canImport(ActivityKit)
        guard let date else { return }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(interval))
            for activity in Activity<ExpenseActivityAttributes>.activities {
                if let closeAt = activity.content.state.autoCloseAt, closeAt <= Date().addingTimeInterval(5) {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            await MainActor.run { self.refreshState() }
        }
        #endif
    }

    #if canImport(ActivityKit)
    private func topCategories(context: ModelContext) -> [ExpenseActivityAttributes.QuickCategory] {
        let descriptor = FetchDescriptor<SpendingCategory>(sortBy: [SortDescriptor(\.sortOrder)])
        let all = (try? context.fetch(descriptor)) ?? []
        let topLevel = all.filter { $0.parent == nil }
        // 以「本月使用次數」排序，取前 4 個當快捷鍵
        let interval = DateHelper.monthInterval()
        let expenses = BudgetService.expenses(in: context, from: interval.start, to: interval.end)
        var usage: [String: Int] = [:]
        for expense in expenses {
            if let root = expense.category?.rootCategory.name {
                usage[root, default: 0] += 1
            }
        }
        let sorted = topLevel.sorted { lhs, rhs in
            let l = usage[lhs.name] ?? 0
            let r = usage[rhs.name] ?? 0
            return l == r ? lhs.sortOrder < rhs.sortOrder : l > r
        }
        return sorted.prefix(4).map {
            ExpenseActivityAttributes.QuickCategory(name: $0.name, iconName: $0.iconName, colorHex: $0.colorHex)
        }
    }
    #endif
}
