import SwiftUI
import Charts
import ChaiNetCore

/// Long-term trends for download, upload, ping, jitter and loss, coloured by network type.
struct HistoryDashboardView: View {
    let results: [TestResult]
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let trends = HistoryAggregator.trends(results)
        VStack(spacing: 14) {
            HStack {
                summaryTile("測試次數", "\(results.count)")
                summaryTile("平均綜合分數", Format.number(Descriptive.mean(results.compactMap { $0.scores.overall.map(Double.init) }), digits: 0))
            }
            ForEach(trends) { trend in
                if !trend.points.isEmpty { TrendCard(trend: trend) }
            }
            if results.isEmpty {
                EmptyStateView(symbol: "chart.xyaxis.line", title: "沒有資料", message: "完成幾次測試後這裡會顯示長期趨勢。")
            }
        }
    }

    private func summaryTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(.title2.weight(.bold).monospacedDigit())
        }
        .cardStyle(padding: 14)
    }
}

private struct TrendCard: View {
    let trend: MetricTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(trend.metric.displayName).font(.headline)
                Spacer()
                Text("中位數 \(Format.number(trend.median, digits: 1)) \(trend.metric.unit)").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Chart {
                if let p10 = trend.p10, let p90 = trend.p90, let first = trend.points.first?.date, let last = trend.points.last?.date, first < last {
                    RectangleMark(xStart: .value("起", first), xEnd: .value("迄", last), yStart: .value("P10", p10), yEnd: .value("P90", p90))
                        .foregroundStyle(Theme.accent.opacity(0.08))
                }
                ForEach(trend.points) { p in
                    PointMark(x: .value("時間", p.date), y: .value(trend.metric.unit, p.value))
                        .foregroundStyle(by: .value("網路", p.network.displayName))
                        .symbolSize(30)
                }
                if let median = trend.median {
                    RuleMark(y: .value("中位數", median)).foregroundStyle(Theme.textSecondary.opacity(0.6)).lineStyle(StrokeStyle(dash: [4, 4]))
                }
            }
            .chartYAxisLabel(trend.metric.unit)
            .frame(height: 160)
            Text("陰影為 P10–P90（正常範圍）；顏色代表網路類型。").font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }
}
