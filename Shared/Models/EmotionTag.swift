import Foundation
import SwiftData

/// 消費情緒標籤（計劃書 §5）。內建三種，並且「可自訂新增」。
@Model
final class EmotionTag {
    var name: String = ""
    var iconName: String = "tag"
    var colorHex: String = "#8E8E93"
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Expense.emotionTag)
    var expenses: [Expense]?

    init(
        name: String,
        iconName: String = "tag",
        colorHex: String = "#8E8E93",
        isBuiltIn: Bool = false,
        sortOrder: Int = 0
    ) {
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.expenses = []
    }

    /// 內建標籤定義：必要 / 衝動 / 享受
    static let builtIns: [(name: String, icon: String, color: String)] = [
        ("必要", "checkmark.seal.fill", "#34C759"),
        ("衝動", "bolt.fill", "#FF3B30"),
        ("享受", "heart.fill", "#FF9F0A")
    ]
}
