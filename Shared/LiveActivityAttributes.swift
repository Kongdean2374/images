import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// 動態島／Live Activity 的資料結構（計劃書 §1-2）。
struct ExpenseActivityAttributes: ActivityAttributes {

    struct QuickCategory: Codable, Hashable, Identifiable {
        var name: String
        var iconName: String
        var colorHex: String
        var id: String { name }
    }

    struct ContentState: Codable, Hashable {
        /// 目前湊到的金額
        var amount: Double = 0
        /// 目前選到的分類
        var categoryName: String = ""
        var categoryIcon: String = "questionmark.circle"
        var categoryColorHex: String = "#8E8E93"
        /// 這個 session 已經記了幾筆 / 多少錢
        var savedCount: Int = 0
        var savedTotal: Double = 0
        var lastSavedAmount: Double?
        /// 本月剩餘額度，記完馬上看得到
        var remaining: Double = 0
        /// 自動關閉時間（可選功能：N 小時後自動結束）
        var autoCloseAt: Date?
    }

    /// 啟動時固定下來的設定
    var startedAt: Date = Date()
    var quickAmounts: [Int] = [50, 100, 500]
    var quickCategories: [QuickCategory] = []
}
#endif
