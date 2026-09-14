import SwiftUI

/// 首頁主視覺用的環形進度
struct RingProgressView: View {
    var progress: Double
    var lineWidth: CGFloat = 12
    var tint: Color = .white
    var trackOpacity: Double = 0.25

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(trackOpacity), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(min(progress, 1), 0.001))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress)
        }
    }
}

/// 一週花費小長條
struct WeekBarStrip: View {
    /// 由舊到新的 7 天資料
    let days: [(date: Date, amount: Double)]
    let dailyAllowance: Double

    private var maxAmount: Double {
        max(days.map(\.amount).max() ?? 0, dailyAllowance, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                            .frame(height: 54)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(item.amount > dailyAllowance && dailyAllowance > 0
                                  ? Color(hex: "#FF453A")
                                  : Theme.accent)
                            .frame(height: max(54 * (item.amount / maxAmount), item.amount > 0 ? 6 : 2))
                    }
                    Text(weekdayLabel(item.date))
                        .font(.system(size: 10))
                        .foregroundStyle(isToday(item.date) ? Color.primary : .secondary)
                        .fontWeight(isToday(item.date) ? .bold : .regular)
                }
            }
        }
    }

    private func isToday(_ date: Date) -> Bool {
        DateHelper.calendar.isDateInToday(date)
    }

    private func weekdayLabel(_ date: Date) -> String {
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        let index = DateHelper.calendar.component(.weekday, from: date) - 1
        return symbols[max(min(index, 6), 0)]
    }
}

/// 篩選用的膠囊按鈕
struct FilterChip: View {
    let title: String
    var systemImage: String?
    var isActive: Bool
    var tint: Color = Theme.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption2.weight(.semibold))
                }
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(isActive ? tint : Color(uiColor: .tertiarySystemFill)))
            .foregroundStyle(isActive ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
