import Foundation

/// 全 App 共用的數值格式化。
enum Fmt {
    /// 距離（輸入公尺）
    static func distance(_ meters: Double?, unit: DistanceUnit = .metric) -> String {
        guard let meters else { return "--" }
        switch unit {
        case .metric:
            if meters < 1000 { return String(format: "%.0f m", meters) }
            return String(format: "%.2f km", meters / 1000)
        case .imperial:
            let miles = meters / 1609.344
            return String(format: "%.2f mi", miles)
        }
    }

    static func distanceValue(_ meters: Double?, unit: DistanceUnit = .metric) -> String {
        guard let meters else { return "--" }
        switch unit {
        case .metric: return String(format: "%.2f", meters / 1000)
        case .imperial: return String(format: "%.2f", meters / 1609.344)
        }
    }

    static func distanceUnitLabel(_ unit: DistanceUnit) -> String {
        unit == .metric ? "公里" : "英里"
    }

    /// 時間長度 → 1:02:03 或 12:34
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// 配速（秒/公里）→ 5'32"
    static func pace(_ secondsPerKM: Double?, unit: DistanceUnit = .metric) -> String {
        guard let secondsPerKM, secondsPerKM.isFinite, secondsPerKM > 0, secondsPerKM < 60 * 90 else { return "--'--\"" }
        let converted = unit == .metric ? secondsPerKM : secondsPerKM * 1.609344
        let m = Int(converted) / 60
        let s = Int(converted) % 60
        return String(format: "%d'%02d\"", m, s)
    }

    static func paceUnitLabel(_ unit: DistanceUnit) -> String {
        unit == .metric ? "/公里" : "/英里"
    }

    static func elevation(_ meters: Double?) -> String {
        guard let meters else { return "--" }
        return String(format: "%.0f m", meters)
    }

    static func integer(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(value)"
    }

    static func decimal(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.\(digits)f", value)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "M/d"
        return f
    }()

    static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "yyyy/MM"
        return f
    }()

    static func date(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func dateTime(_ date: Date) -> String { dayTimeFormatter.string(from: date) }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var displayName: String { self == .metric ? "公制（公里）" : "英制（英里）" }
}
