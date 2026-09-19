import SwiftUI
import Charts

/// C1 分段配速長條圖（點選可與地圖聯動）
struct SplitsChartView: View {
    let splits: [SplitSegment]
    @Binding var selection: SplitSegment?
    var unit: DistanceUnit = .metric

    @State private var selectedLabel: String?

    private var fastest: Double { splits.compactMap { $0.pace }.min() ?? 0 }
    private var slowest: Double { splits.compactMap { $0.pace }.max() ?? 1 }

    private func color(for split: SplitSegment) -> Color {
        guard let pace = split.pace, slowest > fastest else { return Theme.accent }
        let fraction = 1 - (pace - fastest) / (slowest - fastest)
        return Theme.paceColor(fraction: fraction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("分段配速")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let selection {
                    Text("\(selection.label)　\(Fmt.pace(selection.pace, unit: unit))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.mint)
                        .contentTransition(.numericText())
                }
            }

            Chart(splits) { split in
                BarMark(
                    x: .value("分段", split.label),
                    y: .value("配速", split.pace ?? 0)
                )
                .foregroundStyle(color(for: split))
                .opacity(selection == nil || selection?.id == split.id ? 1 : 0.35)
                .cornerRadius(6)
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartXSelection(value: $selectedLabel)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(Fmt.pace(seconds, unit: unit))
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
                            Text(label.replacingOccurrences(of: "第 ", with: "")
                                .replacingOccurrences(of: " 公里", with: "")
                                .replacingOccurrences(of: " 圈", with: ""))
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .frame(height: 190)
            .onChange(of: selectedLabel) { _, newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    selection = splits.first { $0.label == newValue }
                }
                if selection != nil { CueService.shared.impact(.soft) }
            }

            if !splits.isEmpty {
                HStack(spacing: 14) {
                    legendDot(Theme.paceColor(fraction: 1), "快")
                    legendDot(Theme.paceColor(fraction: 0.5), "中")
                    legendDot(Theme.paceColor(fraction: 0), "慢")
                    Spacer()
                    Text("點選長條可高亮對應軌跡")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// 海拔剖面
struct ElevationChartView: View {
    let points: [RoutePoint]

    private var data: [(distance: Double, altitude: Double)] {
        points.map { ($0.distanceFromStart / 1000, $0.altitude) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("海拔剖面")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { item in
                    AreaMark(
                        x: .value("距離", item.element.distance),
                        y: .value("海拔", item.element.altitude)
                    )
                    .foregroundStyle(LinearGradient(colors: [Theme.mint.opacity(0.6), Theme.mint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("距離", item.element.distance),
                        y: .value("海拔", item.element.altitude)
                    )
                    .foregroundStyle(Theme.mint)
                    .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel {
                        if let km = value.as(Double.self) {
                            Text(String(format: "%.1fkm", km))
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel {
                        if let m = value.as(Double.self) {
                            Text("\(Int(m))m")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .frame(height: 150)
        }
    }
}
