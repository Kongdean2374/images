import WidgetKit
import SwiftUI

struct StepsEntry: TimelineEntry {
    let date: Date
    let steps: Int
    let floors: Int
    let distance: Double?
    let goal: Int

    var progress: Double {
        goal > 0 ? min(1, Double(steps) / Double(goal)) : 0
    }
}

struct StepsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StepsEntry {
        StepsEntry(date: Date(), steps: 4820, floors: 6, distance: 3600, goal: 8000)
    }

    func getSnapshot(in context: Context, completion: @escaping (StepsEntry) -> Void) {
        Task {
            let stats = await WidgetPedometer.todayStats()
            completion(StepsEntry(date: Date(),
                                  steps: stats.steps,
                                  floors: stats.floors,
                                  distance: stats.distance,
                                  goal: WidgetPedometer.stepGoal))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StepsEntry>) -> Void) {
        Task {
            let stats = await WidgetPedometer.todayStats()
            let entry = StepsEntry(date: Date(),
                                   steps: stats.steps,
                                   floors: stats.floors,
                                   distance: stats.distance,
                                   goal: WidgetPedometer.stepGoal)
            // 每 15 分鐘更新一次
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct StepsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StepsEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Gauge(value: entry.progress) {
                    Image(systemName: "shoeprints.fill")
                } currentValueLabel: {
                    Text("\(entry.steps / 100)")
                        .font(.system(size: 13, weight: .bold))
                }
                .gaugeStyle(.accessoryCircular)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("今日步數", systemImage: "shoeprints.fill")
                    .font(.caption2)
                Text("\(entry.steps)")
                    .font(.headline)
                ProgressView(value: entry.progress)
                    .progressViewStyle(.linear)
            }
        case .systemMedium:
            HStack(spacing: 18) {
                ring
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日步數")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(entry.steps)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    HStack(spacing: 12) {
                        Label("\(entry.floors) 層", systemImage: "stairs")
                        if let distance = entry.distance {
                            Label(WidgetFormat.distance(distance), systemImage: "figure.walk")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Text("目標 \(entry.goal) 步")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        default:
            VStack(spacing: 8) {
                ring
                Text("\(entry.steps) 步")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("目標 \(entry.goal)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.001, entry.progress))
                .stroke(AngularGradient(colors: [WidgetTheme.accent, WidgetTheme.mint, WidgetTheme.accent],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "shoeprints.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WidgetTheme.accent)
        }
        .frame(width: 66, height: 66)
    }
}

struct StepsWidget: Widget {
    let kind = "StepsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StepsProvider()) { entry in
            StepsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("今日步數")
        .description("顯示今天的步數、爬樓層與目標進度，不需要定位。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
