import Foundation

/// 把口語數字轉成金額：「一百二」=120、「三千五」=3500、「五十塊」=50、「三塊半」=3.5
enum ChineseNumber {

    private static let digits: [Character: Double] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9,
        "0": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9
    ]

    private static let units: [Character: Double] = ["十": 10, "百": 100, "千": 1000, "萬": 10000]

    /// 數字後面接這些就不是金額（日期、時間、數量詞）
    private static let rejectSuffixes: Set<Character> = [
        "號", "月", "日", "樓", "分", "個", "杯", "份", "張", "支", "件", "次", "人", "位", "歲", "點", "成"
    ]

    // MARK: - 從一句話抽金額

    static func extractAmount(from text: String) -> Double? {
        let chars = Array(text)
        let numberSet = Set("0123456789零〇一二三四五六七八九十百千萬兩廿點.")

        struct Candidate {
            var value: Double
            var priority: Int
        }
        var candidates: [Candidate] = []

        var index = 0
        while index < chars.count {
            guard numberSet.contains(chars[index]) else { index += 1; continue }

            var end = index
            while end < chars.count, numberSet.contains(chars[end]) { end += 1 }
            var run = String(chars[index..<end])

            // 後面緊接著的字
            var suffix: Character?
            if end < chars.count { suffix = chars[end] }

            // 「三塊半」
            var halfBonus = 0.0
            if let suffix, suffix == "半" { halfBonus = 0.5 }

            var hasCurrency = false
            if end < chars.count {
                let tail = String(chars[end...])
                if Lexicon.currencyUnits.contains(where: { tail.hasPrefix($0) }) {
                    hasCurrency = true
                    // 「五十塊半」
                    for unit in Lexicon.currencyUnits where tail.hasPrefix(unit) {
                        let afterUnit = tail.dropFirst(unit.count)
                        if afterUnit.hasPrefix("半") { halfBonus = 0.5 }
                        break
                    }
                }
            }
            // 「$100」這種寫在前面的符號
            if index > 0, chars[index - 1] == "$" { hasCurrency = true }

            // 尾巴的點沒有意義就砍掉（「三點」= 三點鐘）
            while run.hasSuffix("點") || run.hasSuffix(".") { run.removeLast() }

            let isPureAscii = run.allSatisfy { $0.isNumber || $0 == "." }
            let shouldReject = !hasCurrency && suffix != nil && rejectSuffixes.contains(suffix!)

            if !shouldReject, let value = self.value(of: run), value > 0 {
                let priority: Int
                if hasCurrency { priority = 3 }
                else if run.count >= 2 || isPureAscii { priority = isPureAscii ? 2 : 1 }
                else { priority = 0 }   // 單一中文字且無單位 → 幾乎都是「一個」「一下」，不採用
                if priority > 0 {
                    candidates.append(Candidate(value: value + halfBonus, priority: priority))
                }
            }
            index = end
        }

        guard !candidates.isEmpty else { return nil }
        let maxPriority = candidates.map(\.priority).max() ?? 0
        return candidates.filter { $0.priority == maxPriority }.map(\.value).max()
    }

    // MARK: - 單一數字字串 → 數值

    static func value(of text: String) -> Double? {
        if text.isEmpty { return nil }

        // 純阿拉伯數字（含小數）
        if let direct = Double(text) { return direct }

        // 「三點五」
        if text.contains("點") {
            let parts = text.components(separatedBy: "點")
            if parts.count == 2,
               let whole = value(of: parts[0]),
               let fraction = fractionValue(parts[1]) {
                return whole + fraction
            }
        }

        var total: Double = 0
        var section: Double = 0
        var current: Double = 0
        var lastUnit: Double = 0
        var sawZero = false
        var asciiRun = ""

        func flushAscii() {
            if !asciiRun.isEmpty {
                current = Double(asciiRun) ?? current
                asciiRun = ""
            }
        }

        for char in text {
            if char.isNumber, char.isASCII {
                asciiRun.append(char)
                continue
            }
            flushAscii()

            if char == "廿" {
                section += 20
                lastUnit = 10
                current = 0
                continue
            }
            if let digit = digits[char] {
                if digit == 0 { sawZero = true } else { current = digit }
                continue
            }
            if let unit = units[char] {
                if unit == 10000 {
                    total += (section + current) * unit
                    section = 0
                    current = 0
                    lastUnit = unit
                } else {
                    if current == 0 { current = 1 }      // 「十五」= 15
                    section += current * unit
                    current = 0
                    lastUnit = unit
                }
                continue
            }
        }
        flushAscii()

        // 口語省略：「一百二」= 120、「三千五」= 3500（看到「零」就不縮放，例如「一百零五」）
        if current > 0, lastUnit >= 100, !sawZero {
            current *= lastUnit / 10
        }

        let result = total + section + current
        return result > 0 ? result : nil
    }

    private static func fractionValue(_ text: String) -> Double? {
        var digitsOnly = ""
        for char in text {
            if char.isNumber, char.isASCII { digitsOnly.append(char) }
            else if let digit = digits[char] { digitsOnly.append(String(Int(digit))) }
            else { break }
        }
        guard !digitsOnly.isEmpty, let value = Double("0." + digitsOnly) else { return nil }
        return value
    }
}
