import Foundation
import SwiftData

/// 一筆支出紀錄。
/// （計劃書中叫 Transaction，這裡改名 Expense 以免和 SwiftUI 內建的 `Transaction` 型別撞名。）
@Model
final class Expense {
    var amount: Double = 0
    var date: Date = Date()
    var note: String?
    var sourceRaw: String = TransactionSource.manual.rawValue
    var merchant: String?
    var createdAt: Date = Date()

    /// 可選：保留原始收據照片。用 externalStorage 避免大圖塞爆資料庫。
    @Attribute(.externalStorage) var receiptImageData: Data?

    var category: SpendingCategory?
    var emotionTag: EmotionTag?

    init(
        amount: Double,
        date: Date = Date(),
        category: SpendingCategory? = nil,
        note: String? = nil,
        emotionTag: EmotionTag? = nil,
        source: TransactionSource = .manual,
        merchant: String? = nil,
        receiptImageData: Data? = nil
    ) {
        self.amount = amount
        self.date = date
        self.category = category
        self.note = note
        self.emotionTag = emotionTag
        self.sourceRaw = source.rawValue
        self.merchant = merchant
        self.receiptImageData = receiptImageData
        self.createdAt = Date()
    }

    var source: TransactionSource {
        get { TransactionSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}
