import SwiftUI
import SwiftData

/// C5 個人紀錄看板
struct PBDashboardView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings
    @State private var shine = false

    private var records: PersonalRecords {
        StatsEngine.personalRecords(sessions: sessions)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if sessions.isEmpty {
                    emptyState
                } else {
                    totalsCard
                    streakCard
                    recordCard(title: "最快平均配速",
                               value: Fmt.pace(records.fastestPace?.value, unit: settings.unit),
                               subtitle: records.fastestPace.map { Fmt.date($0.session.startDate) } ?? "--",
                               icon: "bolt.fill",
                               tint: Theme.accentWarm,
                               session: records.fastestPace?.session)
                    recordCard(title: "最長距離",
                               value: Fmt.distance(records.longestDistance?.value, unit: settings.unit),
                               subtitle: records.longestDistance.map { Fmt.date($0.session.startDate) } ?? "--",
                               icon: "arrow.left.and.right",
                               tint: Theme.accent,
                               session: records.longestDistance?.session)
                    recordCard(title: "最長時間",
                               value: Fmt.duration(records.longestDuration?.value),
                               subtitle: records.longestDuration.map { Fmt.date($0.session.startDate) } ?? "--",
                               icon: "stopwatch.fill",
                               tint: Theme.mint,
                               session: records.longestDuration?.session)
                    recordCard(title: "最大累積爬升",
                               value: Fmt.elevation(records.highestClimb?.value),
                               subtitle: records.highestClimb.map { Fmt.date($0.session.startDate) } ?? "--",
                               icon: "mountain.2.fill",
                               tint: Theme.amber,
                               session: records.highestClimb?.session)
                    recordCard(title: "最高強度",
                               value: Fmt.decimal(records.bestIntensity?.value, digits: 0),
                               subtitle: IntensityCalculator.label(for: records.bestIntensity?.value),
                               icon: "flame.fill",
                               tint: Theme.violet,
                               session: records.bestIntensity?.session)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
        }
        .screenBackground()
        .navigationTitle("個人紀錄")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                shine = true
            }
        }
    }

    private var totalsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("累積總計")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    StatPill(title: "總里程（\(Fmt.distanceUnitLabel(settings.unit))）",
                             value: Fmt.distanceValue(records.totalDistance, unit: settings.unit),
                             tint: Theme.accent)
                    StatPill(title: "總時間",
                             value: Fmt.duration(records.totalDuration),
                             tint: Theme.mint)
                    StatPill(title: "總次數",
                             value: "\(records.totalSessions)",
                             tint: Theme.amber)
                }
            }
        }
    }

    private var streakCard: some View {
        GlassCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Theme.warmGradient)
                        .frame(width: 70, height: 70)
                        .shadow(color: Theme.accentWarm.opacity(0.5), radius: shine ? 16 : 6)
                    VStack(spacing: 0) {
                        Text("\(records.currentStreak)")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .contentTransition(.numericText())
                            .foregroundStyle(.white)
                        Text("天")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("目前連續運動天數")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("最長紀錄 \(records.longestStreak) 天")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if records.currentStreak > 0 {
                        Text("保持下去，別讓連續中斷！")
                            .font(.caption2)
                            .foregroundStyle(Theme.amber)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func recordCard(title: String,
                            value: String,
                            subtitle: String,
                            icon: String,
                            tint: Color,
                            session: WorkoutSession?) -> some View {
        Group {
            if let session {
                NavigationLink {
                    WorkoutDetailView(session: session)
                } label: {
                    recordCardContent(title: title, value: value, subtitle: subtitle, icon: icon, tint: tint)
                }
                .buttonStyle(.plain)
            } else {
                recordCardContent(title: title, value: value, subtitle: subtitle, icon: icon, tint: tint)
            }
        }
    }

    private func recordCardContent(title: String,
                                   value: String,
                                   subtitle: String,
                                   icon: String,
                                   tint: Color) -> some View {
        GlassCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(tint.opacity(0.18))
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(value)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(colors: [.clear, tint.opacity(0.16), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .opacity(shine ? 1 : 0.2)
                    .allowsHitTesting(false)
            )
        }
    }

    private var emptyState: some View {
        EmptyStateView(systemImage: "trophy",
                       title: "還沒有個人紀錄",
                       message: "完成運動後會自動計算最佳成績與連續天數。",
                       tint: Theme.amber)
            .padding(.top, 70)
    }
}
