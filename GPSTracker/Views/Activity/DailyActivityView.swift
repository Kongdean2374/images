import SwiftUI
import Charts

/// 每日活動看板：資料來自 iPhone 內建計步器，
/// 就算沒開 App、沒開定位，也有過去幾天的步數。
struct DailyActivityView: View {
    @StateObject private var provider = DailyActivityProvider()
    @EnvironmentObject private var settings: AppSettings
    @State private var goalText = ""

    private var goal: Int { max(1, settings.dailyStepGoal) }
    private var progress: Double { min(1, Double(provider.todaySteps) / Double(goal)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !provider.isAvailable {
                    unavailableCard
                } else if !provider.hasAnyData && !provider.isLoading {
                    noDataCard
                    goalCard
                } else {
                    todayCard
                    if provider.hasAnyData { weekChartCard }
                    if hasAnyDetail { detailCard }
                    goalCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("每日活動")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            goalText = "\(settings.dailyStepGoal)"
            await provider.load(dayCount: 7)
        }
        .refreshable {
            await provider.load(dayCount: 7)
        }
    }

    private var todayCard: some View {
        GlassCard {
            HStack(spacing: 20) {
                ZStack {
                    RingProgress(progress: progress, lineWidth: 14)
                    VStack(spacing: 2) {
                        Text("\(provider.todaySteps)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.textPrimary)
                        Text("步")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 128, height: 128)

                VStack(alignment: .leading, spacing: 8) {
                    Text("今日")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("目標 \(goal) 步")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(String(format: "完成 %.0f%%", progress * 100))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(progress >= 1 ? Theme.mint : Theme.accent)
                    if progress >= 1 {
                        Label("今日目標已達成", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.mint)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var weekChartCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("近 7 天步數")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if provider.isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                Chart(provider.days) { day in
                    BarMark(
                        x: .value("日期", day.weekdayLabel),
                        y: .value("步數", day.steps)
                    )
                    .foregroundStyle(day.isToday ? Theme.accent : Theme.accent.opacity(0.45))
                    .cornerRadius(6)

                    RuleMark(y: .value("目標", goal))
                        .foregroundStyle(Theme.amber.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                        AxisValueLabel {
                            if let steps = value.as(Int.self) {
                                Text(steps >= 1000 ? "\(steps / 1000)k" : "\(steps)")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let label = value.as(String.self) {
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 180)

                HStack {
                    StatPill(title: "本週合計", value: "\(provider.weekSteps)", tint: Theme.accent)
                    StatPill(title: "最佳一天",
                             value: "\(provider.bestDay?.steps ?? 0)",
                             tint: Theme.amber)
                    StatPill(title: "日平均",
                             value: provider.days.isEmpty ? "0" : "\(provider.weekSteps / max(1, provider.days.count))",
                             tint: Theme.mint)
                }
            }
        }
    }

    private var detailCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("今日其他數據")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    if provider.hasDistanceData {
                        StatPill(title: "步行距離",
                                 value: Fmt.distanceValue(provider.todayDistance, unit: settings.unit),
                                 tint: Theme.accent)
                    }
                    if provider.hasFloorData {
                        StatPill(title: "爬樓層",
                                 value: "\(provider.todayFloors)",
                                 tint: Theme.violet)
                    }
                    if provider.hasTodayData {
                        StatPill(title: "估算熱量",
                                 value: String(format: "%.0f",
                                               Double(provider.todaySteps) * 0.04 * settings.bodyWeight / 65),
                                 tint: Theme.accentWarm)
                    }
                }
                Text("資料由 iPhone 內建計步器提供，不需要定位權限，App 未開啟時系統也持續記錄。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// 今日其他數據裡至少要有一項有值，整張卡才有意義
    private var hasAnyDetail: Bool {
        provider.hasDistanceData || provider.hasFloorData || provider.hasTodayData
    }

    private var noDataCard: some View {
        GlassCard(padding: 18) {
            VStack(spacing: 10) {
                Image(systemName: "shoeprints.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.textSecondary)
                Text("最近 7 天沒有任何活動資料")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("把手機帶在身上走一段，或到「設定 → 健康資料」授權讀取，圖表就會自動出現。沒有資料的項目會先隱藏，不用看一堆 0。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var goalCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("每日步數目標")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    TextField("8000", text: $goalText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                        .onChange(of: goalText) { _, newValue in
                            if let value = Int(newValue), value > 0 {
                                settings.dailyStepGoal = value
                            }
                        }
                    Text("步")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 8) {
                    ForEach([5000, 8000, 10000, 15000], id: \.self) { value in
                        Button {
                            settings.dailyStepGoal = value
                            goalText = "\(value)"
                            CueService.shared.impact(.soft)
                        } label: {
                            Text("\(value / 1000)k")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(settings.dailyStepGoal == value
                                                           ? Theme.accent.opacity(0.3)
                                                           : Color.white.opacity(0.07)))
                                .foregroundStyle(settings.dailyStepGoal == value ? Theme.accent : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var unavailableCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "shoeprints.fill")
                .font(.system(size: 42))
                .foregroundStyle(Theme.textSecondary)
            Text("此裝置不支援計步")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("計圈、間歇、手動輸入等功能仍可正常使用。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 70)
    }
}
