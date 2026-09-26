import SwiftUI
import SwiftData
import Charts

/// 歷史總覽：把本機與匯入的資料一起看，數字大、圖為主。
struct HistoryInsightsView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings

    /// 一次算好，避免每次重繪都重新走訪所有紀錄
    @State private var cached = HistoryInsights()
    @State private var cacheKey = ""

    private var insights: HistoryInsights { cached }

    private func rebuildCacheIfNeeded() {
        let key = "\(sessions.count)-\(sessions.first?.id.uuidString ?? "")"
        guard cacheKey != key else { return }
        cacheKey = key
        cached = HistoryInsightsEngine.build(sessions: sessions)
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if sessions.isEmpty {
                    EmptyStateView(systemImage: "tray",
                                   title: "還沒有資料",
                                   message: "先記錄一次運動，或從健康 App 一鍵匯入歷史紀錄。")
                        .padding(.top, 60)
                } else {
                    let data = insights
                    heroGrid(data)
                    if data.years.count > 1 { yearChart(data) }
                    if data.months.count > 1 { monthChart(data) }
                    sourceCard(data)
                    typeCard(data)
                    recordCard(data)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .onAppear { rebuildCacheIfNeeded() }
        .onChange(of: sessions.count) { _, _ in rebuildCacheIfNeeded() }
        .navigationTitle("歷史總覽")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 數字磚

    private func heroGrid(_ data: HistoryInsights) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            bigTile("總里程", Fmt.distanceValue(data.totalDistance, unit: settings.unit),
                    Fmt.distanceUnitLabel(settings.unit), "map.fill", Theme.accent)
            bigTile("總時間", String(format: "%.0f", data.totalDuration / 3600),
                    "小時", "clock.fill", Theme.mint)
            bigTile("運動次數", "\(data.totalCount)", "次", "flame.fill", Theme.amber)
            bigTile("總消耗", String(format: "%.0f", data.totalCalories / 1000),
                    "千大卡", "bolt.fill", Theme.accentWarm)
            bigTile("累積爬升", String(format: "%.0f", data.totalElevation),
                    "公尺", "mountain.2.fill", Theme.violet)
            bigTile("累積步數", String(format: "%.0f", Double(data.totalSteps) / 1000),
                    "千步", "shoeprints.fill", Theme.mint)
        }
    }

    private func bigTile(_ title: String, _ value: String, _ unit: String,
                         _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(tint.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1))
        )
    }

    // MARK: 年度

    private func yearChart(_ data: HistoryInsights) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("每年里程")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let best = data.busiestYear {
                        Text("最多：\(best.year) 年")
                            .font(.caption)
                            .foregroundStyle(Theme.amber)
                    }
                }
                Chart {
                    ForEach(data.years) { year in
                        BarMark(x: .value("年", String(year.year)),
                                y: .value("里程", year.distance / 1000))
                        .foregroundStyle(Theme.accent.gradient)
                        .cornerRadius(6)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v))")
                                    .font(.system(size: 10))
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
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 170)

                HStack {
                    StatPill(title: "資料涵蓋", value: "\(data.coverageDays) 天", tint: Theme.accent)
                    StatPill(title: "有運動的天數", value: "\(data.activeDays)", tint: Theme.mint)
                    StatPill(title: "平均每週", value: String(format: "%.1f 次", data.averagePerWeek), tint: Theme.amber)
                }
            }
        }
    }

    // MARK: 月度

    private func monthChart(_ data: HistoryInsights) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("近兩年每月里程")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Chart {
                    ForEach(data.months) { month in
                        BarMark(x: .value("月", month.label),
                                y: .value("里程", month.distance / 1000))
                        .foregroundStyle(Theme.mint.gradient)
                        .cornerRadius(4)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisValueLabel {
                            if let label = value.as(String.self) {
                                Text(label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: 來源

    private func sourceCard(_ data: HistoryInsights) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("資料來源")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Chart {
                    ForEach(data.sources) { source in
                        SectorMark(angle: .value("筆數", source.count),
                                   innerRadius: .ratio(0.6),
                                   angularInset: 2)
                        .foregroundStyle(source.isLocal ? Theme.accent : Theme.mint)
                        .cornerRadius(5)
                    }
                }
                .frame(height: 170)

                ForEach(data.sources) { source in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(source.isLocal ? Theme.accent : Theme.mint)
                            .frame(width: 9, height: 9)
                        Text(source.name)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(source.count) 筆")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                        Text(Fmt.distance(source.distance, unit: settings.unit))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(source.isLocal ? Theme.accent : Theme.mint)
                            .frame(width: 78, alignment: .trailing)
                    }
                }

                HStack {
                    StatPill(title: "本機記錄", value: "\(data.localCount)", tint: Theme.accent)
                    StatPill(title: "匯入", value: "\(data.importedCount)", tint: Theme.mint)
                    StatPill(title: "含軌跡", value: "\(data.withRouteCount)", tint: Theme.violet)
                }
            }
        }
    }

    private func typeCard(_ data: HistoryInsights) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("運動類型")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                TypeDistributionChart(shares: data.typeShares)
            }
        }
    }

    private func recordCard(_ data: HistoryInsights) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("全期間最佳")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    StatPill(title: "最長距離",
                             value: Fmt.distance(data.longestDistance, unit: settings.unit),
                             tint: Theme.accent)
                    StatPill(title: "最長時間",
                             value: Fmt.duration(data.longestDuration),
                             tint: Theme.mint)
                    StatPill(title: "最快配速",
                             value: Fmt.pace(data.fastestPace, unit: settings.unit),
                             tint: Theme.accentWarm)
                }
                HStack {
                    StatPill(title: "平均每次",
                             value: Fmt.distance(data.averageDistance, unit: settings.unit),
                             tint: Theme.textPrimary)
                    StatPill(title: "運動日比例",
                             value: String(format: "%.0f%%", data.consistency * 100),
                             tint: Theme.violet)
                    if let first = data.firstDate {
                        StatPill(title: "最早紀錄", value: Fmt.date(first), tint: Theme.amber)
                    }
                }
            }
        }
    }
}
