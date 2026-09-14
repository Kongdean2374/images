import Foundation

/// 一句話解析出來的結果（送進確認畫面用，絕不自動寫入）。
struct ParsedEntry: Identifiable {
    let id = UUID()
    var rawText: String
    var amount: Double?
    var categoryName: String?
    var subCategoryName: String?
    var emotionName: String?
    var date: Date?
    var note: String?
    /// 0~1，低於 0.5 會在確認畫面標黃提醒
    var confidence: Double = 0
    var matchedTerms: [String] = []

    var isUsable: Bool { amount != nil && amount! > 0 }
}

/// 純規則 + 詞庫的解析器。完全本機、不含任何 AI、不連網。
enum VoiceParser {

    // MARK: - 入口

    /// 一句話可能含多筆（「早餐五十然後咖啡六十」）
    static func parse(_ text: String, learned: [PhraseMapping] = []) -> [ParsedEntry] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }

        let segments = split(normalized)
        let entries = segments.compactMap { parseSegment($0, learned: learned) }
        let usable = entries.filter { $0.isUsable }
        // 整句只有一個金額時，就算切成多段也只回傳一筆
        return usable.isEmpty ? entries : usable
    }

    // MARK: - 正規化

    static func normalize(_ text: String) -> String {
        var result = text
            .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        result = result.lowercased()
        result = result.replacingOccurrences(of: " ", with: "")
        result = result.replacingOccurrences(of: "\u{3000}", with: "")
        for (wrong, right) in Lexicon.typoFixes {
            result = result.replacingOccurrences(of: wrong, with: right)
        }
        return result
    }

    private static func split(_ text: String) -> [String] {
        var parts = [text]
        for separator in Lexicon.separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? [text] : cleaned
    }

    // MARK: - 單段解析

    private static func parseSegment(_ segment: String, learned: [PhraseMapping]) -> ParsedEntry? {
        var entry = ParsedEntry(rawText: segment)
        var score = 0.0
        var weight = 0.0

        // 1. 分類（先個人詞庫，再內建詞庫）
        if let learnedHit = matchLearned(segment, learned: learned) {
            entry.categoryName = learnedHit
            entry.matchedTerms.append(learnedHit)
            score += 1.0; weight += 1.0
        } else if let hit = matchCategory(segment) {
            entry.categoryName = hit.category
            entry.subCategoryName = hit.subCategory
            entry.matchedTerms.append(hit.term)
            score += hit.score; weight += 1.0
        } else {
            weight += 1.0
        }

        // 2. 金額
        let amountText = stripNumericNoise(segment)
        if let amount = ChineseNumber.extractAmount(from: amountText) {
            entry.amount = amount
            score += 1.0; weight += 1.0
        } else {
            weight += 1.0
        }

        // 3. 情緒
        if let emotion = matchEmotion(segment) {
            entry.emotionName = emotion
            entry.matchedTerms.append(emotion)
        }

        // 4. 日期
        entry.date = matchDate(segment)

        // 5. 備註：把整段原文留著，使用者自己看
        entry.note = segment

        entry.confidence = weight > 0 ? min(score / weight, 1) : 0
        return entry
    }

    // MARK: - 分類比對（四層）

    struct CategoryHit {
        var category: String
        var subCategory: String?
        var term: String
        var score: Double
    }

    static func matchCategory(_ text: String) -> CategoryHit? {
        var best: CategoryHit?

        func consider(_ candidate: CategoryHit) {
            if best == nil || candidate.score > best!.score ||
                (candidate.score == best!.score && candidate.term.count > best!.term.count) {
                best = candidate
            }
        }

        // 先比子分類（比較精準），再比頂層
        for (sub, terms) in Lexicon.subCategoryTerms {
            for term in terms {
                if let score = similarity(text: text, term: term) {
                    let parent = parentCategory(forSub: sub) ?? sub
                    consider(CategoryHit(category: parent, subCategory: sub, term: term, score: score))
                }
            }
        }
        for (category, terms) in Lexicon.categoryTerms {
            for term in terms {
                if let score = similarity(text: text, term: term) {
                    if let current = best, current.score >= score { continue }
                    consider(CategoryHit(category: category, subCategory: nil, term: term, score: score))
                }
            }
        }
        return best
    }

    private static func parentCategory(forSub sub: String) -> String? {
        switch sub {
        case "早餐", "午餐", "晚餐", "宵夜", "飲料": return "餐飲"
        case "大眾運輸", "加油", "計程車": return "交通"
        case "訂閱服務": return "娛樂"
        case "門診", "藥品": return "醫療"
        default: return nil
        }
    }

    /// 回傳命中分數；沒命中回 nil
    /// 1.0 = 完全包含、0.8 = 拼音命中、0.6 = 拼音模糊（編輯距離 ≤ 門檻）
    static func similarity(text: String, term: String) -> Double? {
        if text.contains(term) { return 1.0 }
        guard term.count >= 2 else { return nil }

        let termPinyin = Pinyin.key(term)
        guard !termPinyin.isEmpty else { return nil }
        let textPinyin = Pinyin.key(text)
        if textPinyin.contains(termPinyin) { return 0.8 }

        // 模糊：用長度相近的視窗比對編輯距離
        let window = termPinyin.count
        guard textPinyin.count >= window, window >= 4 else { return nil }
        let tolerance = window <= 6 ? 1 : 2
        let chars = Array(textPinyin)
        for start in 0...(chars.count - window) {
            let slice = String(chars[start..<(start + window)])
            if Levenshtein.distance(slice, termPinyin) <= tolerance { return 0.6 }
        }
        return nil
    }

    private static func matchLearned(_ text: String, learned: [PhraseMapping]) -> String? {
        let sorted = learned.sorted { $0.hitCount > $1.hitCount }
        for mapping in sorted where !mapping.phrase.isEmpty {
            if text.contains(mapping.phrase) { return mapping.categoryName }
        }
        return nil
    }

    static func matchEmotion(_ text: String) -> String? {
        for (emotion, terms) in Lexicon.emotionTerms {
            for term in terms where text.contains(term) {
                return emotion
            }
        }
        return nil
    }

    // MARK: - 日期

    static func matchDate(_ text: String) -> Date? {
        let calendar = DateHelper.calendar
        var base: Date?

        for (word, offset) in Lexicon.relativeDays where text.contains(word) {
            base = calendar.date(byAdding: .day, value: offset, to: Date())
            break
        }

        // 「X號」
        if base == nil,
           let range = text.range(of: "[0-9]{1,2}號", options: .regularExpression) {
            let digits = text[range].replacingOccurrences(of: "號", with: "")
            if let day = Int(digits), (1...31).contains(day) {
                var components = calendar.dateComponents([.year, .month], from: Date())
                components.day = day
                components.hour = 12
                base = calendar.date(from: components)
            }
        }

        guard var result = base else { return nil }

        for (word, hour) in Lexicon.dayParts where text.contains(word) {
            var components = calendar.dateComponents([.year, .month, .day], from: result)
            components.hour = hour
            if let adjusted = calendar.date(from: components) { result = adjusted }
            break
        }
        return result
    }

    // MARK: - 工具

    /// 從一段話裡萃取出「拿來學習的關鍵片語」：把數字、單位、情緒詞、日期詞都拿掉後剩下的內容。
    static func learningPhrase(for segment: String) -> String {
        var result = normalize(segment)
        for noise in Lexicon.currencyUnits { result = result.replacingOccurrences(of: noise, with: "") }
        for (_, terms) in Lexicon.emotionTerms {
            for term in terms { result = result.replacingOccurrences(of: term, with: "") }
        }
        for (word, _) in Lexicon.relativeDays { result = result.replacingOccurrences(of: word, with: "") }
        for (word, _) in Lexicon.dayParts { result = result.replacingOccurrences(of: word, with: "") }
        result = result.replacingOccurrences(of: "[0-9零〇一二三四五六七八九十百千萬兩廿點.半]", with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(result.prefix(12))
    }

    /// 拿掉本身含數字的店名，免得被當成金額
    private static func stripNumericNoise(_ text: String) -> String {
        var result = text
        for noise in Lexicon.numericNoise {
            result = result.replacingOccurrences(of: noise, with: "")
        }
        return result
    }
}

/// 中文字轉拼音鍵（iOS 內建轉換，離線）。專治同音字。
enum Pinyin {
    private static var cache: [String: String] = [:]

    static func key(_ text: String) -> String {
        if let cached = cache[text] { return cached }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let result = (mutable as String)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if cache.count < 2000 { cache[text] = result }
        return result
    }
}

enum Levenshtein {
    static func distance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
