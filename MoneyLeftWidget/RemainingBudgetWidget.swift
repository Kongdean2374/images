import WidgetKit
import SwiftUI
import AppIntents

struct BudgetEntry: TimelineEntry {
    let date: Date
    let summary: BudgetSummary
}

struct BudgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry {
        BudgetEntry(date: Date(), summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) {
        completion(BudgetEntry(date: Date(), summary: BudgetSnapshotStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        let summary = BudgetSnapshotStore.load() ?? BudgetSummary()
        let entry = BudgetEntry(date: Date(), summary: summary)
        // 每小時更新一次；App 有寫入時也會主動 reload
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct RemainingBudgetWidget: Widget {
    let kind = "RemainingBudgetWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BudgetProvider()) { entry in
            RemainingBudgetWidgetView(summary: entry.summary)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("還能花多少")
        .description("直接在主畫面看本月剩餘可花額度。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct RemainingBudgetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let summary: BudgetSummary

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: min(max(summary.variableSpent / max(summary.spendable, 1), 0), 1)) {
                Image(systemName: "dollarsign")
            } currentValueLabel: {
                Text(Money.compact(max(summary.remaining, 0)))
                    .font(.system(size: 11, weight: .bold))
                    .minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircularCapacity)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("還能花").font(.caption2)
                Text(Money.string(max(summary.remaining, 0)))
                    .font(.headline)
                    .monospacedDigit()
                Text("每天 \(Money.string(summary.dailyAllowance))")
                    .font(.caption2)
            }

        case .systemMedium:
            HStack(spacing: 14) {
                mainBlock
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    metric("每日可花", Money.string(summary.dailyAllowance))
                    metric("燒錢速度", String(format: "%.0f%%", summary.burnRatio * 100), tint: summary.burnLevel.color)
                    quickButtons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        default:
            mainBlock
        }
    }

    private var mainBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本月還能花")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Money.string(max(summary.remaining, 0)))
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(summary.remaining < 0 ? Color(hex: "#FF453A") : .primary)
            ProgressView(value: min(max(summary.variableSpent / max(summary.spendable, 1), 0), 1))
                .tint(summary.burnLevel.color)
            Text("剩 \(summary.daysRemaining) 天 · 每天 \(Money.string(summary.dailyAllowance))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Link(destination: URL(string: "\(AppGroup.urlScheme)://add") ?? URL(string: "https://example.com")!) {
                Label("記一筆", systemImage: "plus.circle.fill")
                    .font(.caption2.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 互動式按鈕：不用開 App 就記一筆
    private var quickButtons: some View {
        HStack(spacing: 6) {
            ForEach(AppSettings.quickAmounts.prefix(2), id: \.self) { value in
                Button(intent: QuickAddExpenseIntent(amount: Double(value))) {
                    Text("+\(value)")
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Link(destination: URL(string: "\(AppGroup.urlScheme)://voice") ?? URL(string: "https://example.com")!) {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.top, 2)
    }

    private func metric(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.footnote, design: .rounded).weight(.semibold)).foregroundStyle(tint).monospacedDigit()
        }
    }
}
