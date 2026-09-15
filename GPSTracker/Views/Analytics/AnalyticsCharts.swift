import SwiftUI
import Charts

// MARK: - C2 歷史趨勢

enum TrendMetric: String, CaseIterable, Identifiable {
    case distance, pace, count, intensity
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .distance: return "總里程"
        case .pace: return "平均配速"
        case .count: return "運動次數"
        case .intensity: return "平均強度"
        }
    }
    var tint: Color {
        switch self {
        case .distance: return Theme.accent
        case .pace: return Theme.mint
        case .count: return Theme.amber
        case .intensity: return Theme.violet
        }
    }
}

struct TrendChartView: View {
    let buckets: [TrendBucket]
    let metric: TrendMetric
    var unit: DistanceUnit = .metric

    private func value(_ bucket: TrendBucket) -> Double {
        switch metric {
        case .distance: return bucket.totalDistance / (unit == .metric ? 1000 : 1609.344)
        case .pace: return bucket.averagePace ?? 0
        case .count: return Double(bucket.count)
        case .intensity: return bucket.intensity
        }
    }

    private var nonZero: [TrendBucket] {
        buckets.filter { value($0) > 0 }
    }

    var body: some View {
        Chart {
            ForEach(metric == .pace ? nonZero : buckets) { bucket in
                if metric == .count {
                    BarMark(x: .value("期間", bucket.label),
                            y: .value(metric.displayName, value(bucket)))
                        .foregroundStyle(metric.tint.gradient)
                        .cornerRadius(6)
                } else {
                    AreaMark(x: .value("期間", bucket.label),
                             y: .value(metric.displayName, value(bucket)))
                        .foregroundStyle(LinearGradient(colors: [metric.tint.opacity(0.45), metric.tint.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("期間", bucket.label),
                             y: .value(metric.displayName, value(bucket)))
                        .foregroundStyle(metric.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("期間", bucket.label),
                              y: .value(metric.displayName, value(bucket)))
                        .foregroundStyle(metric.tint)
                        .symbolSize(28)
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: metric == .count, reversed: metric == .pace))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(metric == .pace ? Fmt.pace(v, unit: unit) : Fmt.decimal(v, digits: metric == .count ? 0 : 1))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .frame(height: 210)
        .animation(.easeInOut(duration: 0.45), value: metric)
    }
}

// MARK: - C3 同路線比較

struct RouteComparisonChart: View {
    let sessions: [WorkoutSession]
    var unit: DistanceUnit = .metric

    private struct Item: Identifiable {
        let id = UUID()
        let label: String
        let pace: Double
        let index: Int
    }

    private var items: [Item] {
        sessions.enumerated().compactMap { index, session in
            guard let pace = session.averagePace else { return nil }
            return Item(label: Fmt.shortDayFormatter.string(from: session.startDate), pace: pace, index: index)
        }
    }

    private var improvement: Double? {
        guard let first = items.first?.pace, let last = items.last?.pace, first > 0 else { return nil }
        return (first - last) / first * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let improvement {
                HStack(spacing: 6) {
                    Image(systemName: improvement >= 0 ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill")
                        .foregroundStyle(improvement >= 0 ? Theme.mint : Theme.accentWarm)
                    Text(improvement >= 0
                         ? String(format: "比第一次快了 %.1f%%", improvement)
                         : String(format: "比第一次慢了 %.1f%%", -improvement))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(improvement >= 0 ? Theme.mint : Theme.accentWarm)
                }
            }
            Chart {
                ForEach(items) { item in
                    BarMark(x: .value("日期", item.label),
                            y: .value("配速", item.pace))
                        .foregroundStyle(Theme.accent.gradient)
                        .cornerRadius(6)
                }
                if let best = items.min(by: { $0.pace < $1.pace }) {
                    RuleMark(y: .value("最佳", best.pace))
                        .foregroundStyle(Theme.amber.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("最佳 \(Fmt.pace(best.pace, unit: unit))")
                                .font(.caption2)
                                .foregroundStyle(Theme.amber)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Fmt.pace(v, unit: unit))
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .frame(height: 190)
        }
    }
}

// MARK: - C4 心肺負荷熱力圖

struct IntensityHeatmap: View {
    let sessions: [WorkoutSession]

    private struct Cell: Identifiable {
        let id = UUID()
        let weekOffset: Int
        let weekday: Int
        let intensity: Double
        let date: Date
    }

    private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    private var cells: [Cell] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var map: [Date: Double] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startDate)
            map[day] = max(map[day] ?? 0, session.intensityScore ?? 30)
        }
        var result: [Cell] = []
        for offset in 0..<84 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day) - 1
            result.append(Cell(weekOffset: offset / 7,
                               weekday: weekday,
                               intensity: map[day] ?? 0,
                               date: day))
        }
        return result
    }

    private func color(_ intensity: Double) -> Color {
        if intensity <= 0 { return Color.white.opacity(0.06) }
        return Theme.paceColor(fraction: min(1, intensity / 90)).opacity(0.35 + min(0.65, intensity / 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(cells) { cell in
                RectangleMark(
                    x: .value("週", -cell.weekOffset),
                    y: .value("星期", weekdayNames[cell.weekday])
                )
                .foregroundStyle(color(cell.intensity))
                .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .frame(height: 150)

            HStack(spacing: 5) {
                Text("低").font(.caption2).foregroundStyle(Theme.textSecondary)
                ForEach([10.0, 30.0, 50.0, 70.0, 90.0], id: \.self) { value in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(value))
                        .frame(width: 18, height: 10)
                }
                Text("高").font(.caption2).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("近 12 週")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - C6 運動類型分佈

struct TypeDistributionChart: View {
    let shares: [TypeShare]

    private var totalDuration: TimeInterval {
        max(1, shares.reduce(0) { $0 + $1.duration })
    }

    var body: some View {
        VStack(spacing: 14) {
            Chart(shares) { share in
                SectorMark(
                    angle: .value("時數", share.duration),
                    innerRadius: .ratio(0.58),
                    angularInset: 2
                )
                .foregroundStyle(Theme.color(for: share.type))
                .cornerRadius(5)
            }
            .frame(height: 210)

            VStack(spacing: 8) {
                ForEach(shares) { share in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.color(for: share.type))
                            .frame(width: 9, height: 9)
                        Text(share.type.displayName)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(share.count) 次")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                        Text(Fmt.duration(share.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                        Text(String(format: "%.0f%%", share.duration / totalDuration * 100))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.color(for: share.type))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - C8 天氣關聯

struct WeatherScatterChart: View {
    let points: [StatsEngine.WeatherPoint]
    var unit: DistanceUnit = .metric

    var body: some View {
        Chart(points) { point in
            PointMark(
                x: .value("氣溫", point.temperature),
                y: .value("配速", point.pace)
            )
            .foregroundStyle(Theme.paceColor(fraction: min(1, max(0, (32 - point.temperature) / 24))))
            .symbolSize(90)
        }
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel {
                    if let t = value.as(Double.self) {
                        Text("\(Int(t))°C")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Fmt.pace(v, unit: unit))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .frame(height: 200)
    }
}


// MARK: - 步頻趨勢

struct CadencePoint: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let cadence: Double
}

struct CadenceTrendChart: View {
    let points: [CadencePoint]
    var reference: Double = 175

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("步頻", point.cadence)
                )
                .foregroundStyle(Theme.mint)
                .interpolationMethod(.catmullRom)
            }
            ForEach(points) { point in
                PointMark(
                    x: .value("日期", point.date),
                    y: .value("步頻", point.cadence)
                )
                .foregroundStyle(Theme.mint)
                .symbolSize(22)
            }
            RuleMark(y: .value("建議步頻", reference))
                .foregroundStyle(Theme.amber.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Fmt.shortDayFormatter.string(from: date))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .frame(height: 150)
    }
}

// MARK: - 訓練負荷長條圖

struct TrainingLoadChart: View {
    let daily: [DailyLoad]
    let average: Double

    private var upperBound: Double {
        max(60, (daily.map { $0.load }.max() ?? 0) * 1.15, average * 1.4)
    }

    var body: some View {
        Chart {
            ForEach(daily) { day in
                BarMark(
                    x: .value("日期", day.date, unit: .day),
                    y: .value("負荷", day.load)
                )
                .foregroundStyle(Theme.accent.opacity(0.75))
                .cornerRadius(3)
            }
            RuleMark(y: .value("四週日均", average))
                .foregroundStyle(Theme.amber.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
        .chartYScale(domain: 0...upperBound)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Fmt.shortDayFormatter.string(from: date))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .frame(height: 150)
    }
}
