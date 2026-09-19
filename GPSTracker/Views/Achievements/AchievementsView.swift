import SwiftUI
import SwiftData

/// 徽章牆
struct AchievementsView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @State private var category: AchievementCategory?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var achievements: [Achievement] {
        AchievementEngine.evaluate(sessions: sessions)
    }

    private var filtered: [Achievement] {
        guard let category else { return achievements }
        return achievements.filter { $0.category == category }
    }

    private var unlockedCount: Int {
        achievements.filter { $0.unlocked }.count
    }

    var body: some View {
        VStack(spacing: 14) {
            summaryCard
            filterBar
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filtered) { achievement in
                        badge(achievement)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private var summaryCard: some View {
        let next = AchievementEngine.highlights(achievements).first
        return GlassCard {
            VStack(spacing: 14) {
                HStack(spacing: 18) {
                    ZStack {
                        RingProgress(progress: achievements.isEmpty ? 0 : Double(unlockedCount) / Double(achievements.count),
                                     lineWidth: 11,
                                     gradient: AngularGradient(colors: [AchievementTier.bronze.color,
                                                                        AchievementTier.gold.color,
                                                                        AchievementTier.platinum.color],
                                                               center: .center))
                        VStack(spacing: 0) {
                            Text("\(unlockedCount)")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(Theme.textPrimary)
                            Text("/ \(achievements.count)")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("已解鎖徽章")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let next {
                            Text("最接近：\(next.title)")
                                .font(.caption)
                                .foregroundStyle(Theme.amber)
                            Text(next.progressText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("全部達成，太猛了")
                                .font(.caption)
                                .foregroundStyle(Theme.mint)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", icon: "square.grid.2x2", selected: category == nil) { category = nil }
                ForEach(AchievementCategory.allCases) { item in
                    chip(title: item.displayName, icon: item.icon, selected: category == item) {
                        category = item
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? Theme.accent.opacity(0.3) : Color.white.opacity(0.07)))
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func badge(_ achievement: Achievement) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(achievement.unlocked
                          ? achievement.tier.color.opacity(0.22)
                          : Color.white.opacity(0.05))
                Circle()
                    .stroke(achievement.unlocked
                            ? achievement.tier.color.opacity(0.7)
                            : Color.white.opacity(0.12), lineWidth: 2)
                if !achievement.unlocked {
                    Circle()
                        .trim(from: 0, to: max(0.01, achievement.progress))
                        .stroke(achievement.tier.color.opacity(0.75),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-5)
                }
                Image(systemName: achievement.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(achievement.unlocked ? achievement.tier.color : Theme.textSecondary)
                if achievement.unlocked {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(achievement.tier.color)
                        .offset(x: 24, y: 24)
                }
            }
            .frame(width: 72, height: 72)
            .shadow(color: achievement.unlocked ? achievement.tier.color.opacity(0.35) : .clear, radius: 10)

            Text(achievement.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(achievement.unlocked ? Theme.textPrimary : Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(achievement.unlocked ? achievement.detail : achievement.progressText)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 168)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(achievement.unlocked ? achievement.tier.color.opacity(0.35) : Theme.cardStroke,
                            lineWidth: 1))
        )
        .opacity(achievement.unlocked ? 1 : 0.72)
    }
}
