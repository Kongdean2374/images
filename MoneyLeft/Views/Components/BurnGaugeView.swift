import SwiftUI

/// 燒錢速度儀表（計劃書 §4）：綠 / 黃 / 紅。
struct BurnGaugeView: View {
    let summary: BudgetSummary
    var lineWidth: CGFloat = 14

    /// 把 burnRatio 壓到 0...1 的刻度（1.0 的速度落在 2/3 的位置）
    private var progress: Double {
        min(max(summary.burnRatio / 1.5, 0), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(135))

                Circle()
                    .trim(from: 0, to: 0.75 * progress)
                    .stroke(
                        AngularGradient(
                            colors: [Color(hex: "#34C759"), Color(hex: "#FFD60A"), Color(hex: "#FF453A")],
                            center: .center,
                            startAngle: .degrees(135),
                            endAngle: .degrees(135 + 270)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(135))
                    .animation(.easeOut(duration: 0.5), value: progress)

                VStack(spacing: 2) {
                    Text(String(format: "%.0f%%", summary.burnRatio * 100))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("的理想速度")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 130)

            Label(summary.burnLevel.label, systemImage: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(summary.burnLevel.color)
        }
    }

    private var iconName: String {
        switch summary.burnLevel {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .over: return "flame.fill"
        }
    }
}

/// 分類小圖示
struct CategoryBadge: View {
    let iconName: String
    let colorHex: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: colorHex), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}
