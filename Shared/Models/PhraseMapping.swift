import Foundation
import SwiftData

/// 個人化詞庫：使用者在確認畫面改掉分類時記下來，下次講同樣的話直接命中。
/// 這是「不用 AI 也會越用越準」的關鍵。
@Model
final class PhraseMapping {
    /// 正規化後的片語（已轉半形、去空白、小寫）
    var phrase: String = ""
    /// 對應到的分類名稱（用名稱而非 ID，換裝置或還原備份也不會斷）
    var categoryName: String = ""
    var hitCount: Int = 1
    var updatedAt: Date = Date()

    init(phrase: String, categoryName: String) {
        self.phrase = phrase
        self.categoryName = categoryName
        self.hitCount = 1
        self.updatedAt = Date()
    }
}
