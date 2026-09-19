import SwiftUI

/// 空狀態：用圖示與一句話說明，取代空白圖表。
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var tint: Color = Theme.accent
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                Circle()
                    .stroke(tint.opacity(0.28), lineWidth: 1)
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 22 : 30, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: compact ? 54 : 76, height: compact ? 54 : 76)

            Text(title)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 14 : 26)
    }
}

/// 進度條式的「還差多少」提示
struct ProgressHint: View {
    let title: String
    let current: Int
    let target: Int
    var tint: Color = Theme.accent

    private var fraction: Double {
        target > 0 ? min(1, Double(current) / Double(target)) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(current) / \(target)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * max(0.02, fraction))
                        .animation(.easeOut(duration: 0.5), value: fraction)
                }
            }
            .frame(height: 6)
        }
    }
}
