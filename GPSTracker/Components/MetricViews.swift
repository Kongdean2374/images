import SwiftUI

/// 大數字指標，數字更新使用捲動動畫。
struct MetricTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    var systemImage: String? = nil
    var tint: Color = Theme.textPrimary
    var size: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                }
                Text(title)
                    .font(.caption)
                    .textCase(.uppercase)
                    .kerning(0.8)
            }
            .foregroundStyle(Theme.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(unit == nil ? value : "\(value) \(unit ?? "")")
    }
}

struct StatPill: View {
    let title: String
    let value: String
    var tint: Color = Theme.accent

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// 圓形主控制按鈕
struct CircleControlButton: View {
    let systemImage: String
    var title: String? = nil
    var tint: Color = Theme.accent
    var diameter: CGFloat = 76
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                    Circle()
                        .stroke(tint.opacity(0.65), lineWidth: 2)
                    Image(systemName: systemImage)
                        .font(.system(size: diameter * 0.34, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: diameter, height: diameter)
                if let title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title ?? systemImage)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: LinearGradient = Theme.accentGradient

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Theme.cardStroke, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 環形進度
struct RingProgress: View {
    var progress: Double
    var accessibilityTitle: String? = nil
    var lineWidth: CGFloat = 14
    var gradient: AngularGradient = AngularGradient(colors: [Theme.accent, Theme.mint, Theme.accent],
                                                    center: .center)

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: progress)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityTitle ?? "進度")
        .accessibilityValue(String(format: "%.0f%%", min(1, max(0, progress)) * 100))
    }
}
