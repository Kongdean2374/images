import Foundation
import SwiftData

/// 分類。支援「子分類」（可選功能：計劃書 §6 保留擴充彈性）。
/// 所有屬性都給預設值、關聯都是 optional —— 這是 SwiftData + CloudKit 同步的硬性要求。
@Model
final class SpendingCategory {
    var name: String = ""
    var iconName: String = "questionmark.circle"
    var colorHex: String = "#8E8E93"
    var isDefault: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    /// 父分類（nil 代表自己就是頂層分類）
    var parent: SpendingCategory?

    @Relationship(deleteRule: .cascade, inverse: \SpendingCategory.parent)
    var children: [SpendingCategory]?

    @Relationship(deleteRule: .nullify, inverse: \Expense.category)
    var expenses: [Expense]?

    init(
        name: String,
        iconName: String = "questionmark.circle",
        colorHex: String = "#8E8E93",
        isDefault: Bool = false,
        sortOrder: Int = 0,
        parent: SpendingCategory? = nil
    ) {
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.isDefault = isDefault
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.parent = parent
        self.children = []
        self.expenses = []
    }

    var sortedChildren: [SpendingCategory] {
        (children ?? []).sorted { $0.sortOrder == $1.sortOrder ? $0.createdAt < $1.createdAt : $0.sortOrder < $1.sortOrder }
    }

    var isTopLevel: Bool { parent == nil }

    /// 顯示用全名：「餐飲 · 午餐」
    var fullName: String {
        if let parent { return "\(parent.name) · \(name)" }
        return name
    }

    /// 統計時歸戶到頂層分類。
    var rootCategory: SpendingCategory {
        parent?.rootCategory ?? self
    }
}
