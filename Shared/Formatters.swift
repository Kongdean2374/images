import Foundation

enum Money {
    /// 「$1,234」樣式。App 全程只處理新台幣整數為主，但保留小數能力。
    static func string(_ value: Double, showsDecimal: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = showsDecimal ? 2 : 0
        formatter.minimumFractionDigits = 0
        let number = NSNumber(value: value)
        let text = formatter.string(from: number) ?? "\(Int(value))"
        return "$\(text)"
    }

    static func compact(_ value: Double) -> String {
        let abs = Swift.abs(value)
        if abs >= 10000 {
            return String(format: "$%.1f萬", value / 10000)
        }
        return string(value)
    }
}

enum DateHelper {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_Hant_TW")
        return c
    }

    static func monthInterval(for date: Date = Date()) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 86400 * 30)
    }

    static func daysInMonth(for date: Date = Date()) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    static func dayOfMonth(for date: Date = Date()) -> Int {
        calendar.component(.day, from: date)
    }

    static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    static func mediumDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "yyyy/M/d (EEE)"
        return f.string(from: date)
    }

    static func csvDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
