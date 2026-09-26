import WidgetKit
import SwiftUI
import CoreMotion
import Charts

struct WeekStepsEntry: TimelineEntry {
    struct Day: Identifiable {
        let id = UUID()
        let date: Date
        let steps: Int
        var label: String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_TW")
            f.dateFormat = "E"
            return f.string(from: date)
        }
        var isToday: Bool { Calendar.current.isDateInToday(date) }
    }

    let date: Date
    let days: [Day]
    let goal: Int

    var total: Int { days.reduce(0) { $0 + $1.steps } }
    var best: Int { days.map { $0.steps }.max() ?? 0 }
    var average: Int { days.isEmpty ? 0 : total / days.count }
}

struct WeekStepsProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeekStepsEntry {
        sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (WeekStepsEntry) -> Void) {
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeekStepsEntry>) -> Void) {
        Task {
            let entry = await load()
            let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func sample() -> WeekStepsEntry {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let values = [6200, 9100, 4300, 11200, 7800, 5400, 8300]
        let days = (0..<7).compactMap { offset -> WeekStepsEntry.Day? in
            guard let date = calendar.date(byAdding: .day, value: -6 + offset, to: today) else { return nil }
            return WeekStepsEntry.Day(date: date, steps: values[offset])
        }
        return WeekStepsEntry(date: Date(), days: days, goal: 8000)
    }

    private func load() async -> WeekStepsEntry {
        guard CMPedometer.isStepCountingAvailable() else {
            return WeekStepsEntry(date: Date(), days: [], goal: WidgetPedometer.stepGoal)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let pedometer = CMPedometer()
        var days: [WeekStepsEntry.Day] = []

        for offset in stride(from: 6, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let end = min(Date(), calendar.date(byAdding: .day, value: 1, to: start) ?? Date())
            guard end > start else { continue }
            let steps: Int = await withCheckedContinuation { continuation in
                pedometer.queryPedometerData(from: start, to: end) { data, _ in
                    continuation.resume(returning: data?.numberOfSteps.intValue ?? 0)
                }
            }
            days.append(WeekStepsEntry.Day(date: start, steps: steps))
        }
        return WeekStepsEntry(date: Date(), days: days, goal: WidgetPedometer.stepGoal)
    }
}

struct WeekStepsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WeekStepsEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("本週步數", systemImage: "figure.walk")
                    .font(.caption2)
                Text("\(entry.total)")
                    .font(.headline)
                Text("日均 \(entry.average)")
                    .font(.caption2)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("本週步數", systemImage: "figure.walk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entry.total)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                if entry.days.isEmpty {
                    Text("沒有計步資料")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(entry.days) { day in
                            BarMark(x: .value("日", day.label),
                                    y: .value("步數", day.steps))
                            .foregroundStyle(day.isToday ? WidgetTheme.accent : WidgetTheme.accent.opacity(0.45))
                            .cornerRadius(3)
                        }
                        RuleMark(y: .value("目標", entry.goal))
                            .foregroundStyle(WidgetTheme.amber.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let label = value.as(String.self) {
                                    Text(label)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    HStack {
                        Text("日均 \(entry.average)")
                        Spacer()
                        Text("最佳 \(entry.best)")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct WeekStepsWidget: Widget {
    let kind = "WeekStepsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeekStepsProvider()) { entry in
            WeekStepsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("本週步數")
        .description("最近 7 天的步數長條圖與目標線，不需要定位。")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}
