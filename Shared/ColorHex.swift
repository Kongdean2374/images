import SwiftUI

extension Color {
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        switch cleaned.count {
        case 8:
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        default:
            r = 0.55; g = 0.55; b = 0.58; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// 常用色票，分類管理頁的調色盤。
    static let palette: [String] = [
        "#FF6B6B", "#FF9F0A", "#FFD60A", "#34C759", "#30D158",
        "#00C7BE", "#32ADE6", "#0A84FF", "#5E5CE6", "#BF5AF2",
        "#FF375F", "#8E8E93"
    ]
}

extension BurnLevel {
    var color: Color {
        switch self {
        case .good: return Color(hex: "#34C759")
        case .warning: return Color(hex: "#FFD60A")
        case .over: return Color(hex: "#FF453A")
        }
    }
}
