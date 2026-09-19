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
        routeGradient(fraction: fraction)
    }

    /// 軌跡漸層：深藍 → 青 → 綠 → 黃 → 橘 → 紅。
    /// 用明確的色站而不是純 hue 旋轉，中間不會出現偏綠的死區，亮度也比較均勻。
    static func routeGradient(fraction: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0.20, 0.45, 0.95)),
            (0.22, (0.20, 0.72, 0.98)),
            (0.44, (0.16, 0.86, 0.66)),
            (0.64, (0.86, 0.90, 0.30)),
            (0.82, (1.00, 0.68, 0.22)),
            (1.00, (1.00, 0.32, 0.28))
        ]
        let t = min(max(fraction, 0), 1)
        for index in 0..<(stops.count - 1) {
            let (p0, c0) = stops[index]
            let (p1, c1) = stops[index + 1]
            if t <= p1 {
                let local = (t - p0) / max(0.0001, p1 - p0)
                return Color(red: c0.0 + (c1.0 - c0.0) * local,
                             green: c0.1 + (c1.1 - c0.1) * local,
                             blue: c0.2 + (c1.2 - c0.2) * local)
            }
        }
        let last = stops[stops.count - 1].1
        return Color(red: last.0, green: last.1, blue: last.2)
    }

    static func color(for category: SportCategory) -> Color {
        switch category {
        case .endurance: return accent
        case .ball: return amber
        case .strength: return accentWarm
        case .mindBody: return violet
        case .water: return Color(red: 0.36, green: 0.78, blue: 0.98)
        case .outdoor: return mint
        case .other: return Color.gray
        }
    }

    static func color(for type: WorkoutType) -> Color {
        switch type {
        case .gpsRun: return accent
        case .gpsHike: return mint
        case .walk: return Color(red: 0.36, green: 0.78, blue: 0.98)
        case .run: return accent
        case .treadmill: return Color(red: 0.98, green: 0.6, blue: 0.35)
        case .lapCounter: return amber
        case .indoorInterval: return accentWarm
        case .indoorReps: return violet
        case .plank: return Color(red: 0.42, green: 0.86, blue: 0.78)
        case .stairs: return Color(red: 0.98, green: 0.52, blue: 0.62)
        case .shuttleRun: return Color(red: 0.36, green: 0.72, blue: 0.98)
        case .ruck: return Color(red: 0.72, green: 0.62, blue: 0.42)
        case .gpsActivity: return Color(red: 0.45, green: 0.80, blue: 0.62)
        case .timedActivity: return Color(red: 0.62, green: 0.58, blue: 0.95)
        case .fitnessTest: return Color(red: 0.95, green: 0.82, blue: 0.35)
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
