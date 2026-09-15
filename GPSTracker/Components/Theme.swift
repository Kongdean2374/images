import SwiftUI
import CoreLocation

/// 深色優先的視覺主題。
enum Theme {
    static let bgTop = Color(red: 0.039, green: 0.055, blue: 0.125)
    static let bgBottom = Color(red: 0.063, green: 0.102, blue: 0.180)
    static let card = Color.white.opacity(0.07)
    static let cardStroke = Color.white.opacity(0.12)
    static let accent = Color(red: 0.196, green: 0.478, blue: 0.902)
    static let accentWarm = Color(red: 1.0, green: 0.376, blue: 0.282)
    static let mint = Color(red: 0.207, green: 0.851, blue: 0.635)
    static let amber = Color(red: 1.0, green: 0.741, blue: 0.259)
    static let violet = Color(red: 0.553, green: 0.404, blue: 0.965)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)

    static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
    }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, mint], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var warmGradient: LinearGradient {
        LinearGradient(colors: [amber, accentWarm], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 配速色：慢 → 藍，快 → 紅
    static func paceColor(fraction: Double) -> Color {
        let t = min(max(fraction, 0), 1)
        return Color(hue: 0.58 * (1 - t), saturation: 0.85, brightness: 1.0)
    }

    static func color(for type: WorkoutType) -> Color {
        switch type {
        case .gpsRun: return accent
        case .gpsHike: return mint
        case .lapCounter: return amber
        case .indoorInterval: return accentWarm
        case .indoorReps: return violet
        case .manualEntry: return Color.gray
        }
    }
}

/// 卡片容器
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Theme.cardStroke, lineWidth: 1)
                    )
            )
    }
}

/// 螢幕底色
struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }

    @ViewBuilder
    func ifLet<T, V: View>(_ value: T?, transform: (Self, T) -> V) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
