import SwiftUI
import UIKit

/// Design tokens. Dark-first, with a complete light palette.
enum Theme {
    static let background = Color(light: 0xF3F5F9, dark: 0x0B0D12)
    static let surface = Color(light: 0xFFFFFF, dark: 0x141821)
    static let surfaceRaised = Color(light: 0xEEF1F6, dark: 0x1B2029)
    static let border = Color(light: 0xE1E5EC, dark: 0x252B36)
    static let textPrimary = Color(light: 0x0F172A, dark: 0xF1F5F9)
    static let textSecondary = Color(light: 0x5B6475, dark: 0x94A3B8)

    static let accent = Color(light: 0x0D9488, dark: 0x2DD4BF)
    static let download = Color(light: 0x0284C7, dark: 0x38BDF8)
    static let upload = Color(light: 0x7C3AED, dark: 0xA78BFA)
    static let latency = Color(light: 0xD97706, dark: 0xFBBF24)
    static let good = Color(light: 0x059669, dark: 0x34D399)
    static let warning = Color(light: 0xD97706, dark: 0xFBBF24)
    static let critical = Color(light: 0xDC2626, dark: 0xF87171)
    static let info = Color(light: 0x2563EB, dark: 0x60A5FA)

    static let cornerRadius: CGFloat = 18
    static let spacing: CGFloat = 16

    /// Colour for a 0–100 quality score.
    static func scoreColor(_ score: Int?) -> Color {
        guard let score else { return textSecondary }
        switch score {
        case 80...: return good
        case 60..<80: return accent
        case 40..<60: return warning
        default: return critical
        }
    }
}

extension Color {
    /// Dynamic colour from two 0xRRGGBB values.
    init(light: UInt32, dark: UInt32) {
        self = Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// Standard card styling.
    func cardStyle(padding: CGFloat = Theme.spacing) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    /// Page background for scroll views.
    func screenBackground() -> some View {
        self.background(Theme.background.ignoresSafeArea())
    }
}
