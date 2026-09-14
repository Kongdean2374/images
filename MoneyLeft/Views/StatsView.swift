import SwiftUI
import SwiftData
import Charts

/// 統計與報表（計劃書 §4 燒錢曲線 + §5 情緒佔比 + §10 報表）
struct StatsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]

    @State private var period: Period = .month
    @State private var anchor: Date = Date()
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()

    enum Period: String, CaseIterable, Identifiable {
        case week = "週"
        case month = "月"
        case custom = "自訂"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    picker
                    if period == .custom { customRange } else { periodNavigator }
                    summaryCard
                    if period == .month { burnChart }
                    categoryChart
                    dailyChart
                    emotionChart
                    sourceBreakdown
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("報表")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 區間

    private var range: DateInterval {
        switch period {
        case .week:
            let calendar = DateHelper.calendar
            let interval = calendar.dateInterval(of: .weekOfYear, for: anchor)
            return interval ?? DateInterval(start: anchor, duration: 604800)
        case .month:
            return DateHelper.monthInterval(for: anchor)
        case .custom:
            let start = DateHelper.startOfDay(min(customStart, customEnd))
            let end = DateHelper.startOfDay(max(customStart, customEnd)).addingTimeInterval(86400)
            return DateInterval(start: start, end: end)
        }
    }

    private var previousRange: DateInterval {
        let duration = range.duration
        return DateInterval(start: range.start.addingTimeInterval(-duration), duration: duration)
    }

    private var expenses: [Expense] {
        allExpenses.filter { $0.date >= range.start && $0.date < range.end }
    }

    private var previousExpenses: [Expense] {
        allExpenses.filter { $0.date >= previousRange.start && $0.date < previousRange.end }
    }

    private var total: Double { expenses.reduce(0) { $0 + $1.amount } }
    private var previousTotal: Double { previousExpenses.reduce(0) { $0 + $1.amount } }

    private var changePercent: Double? {
        guard previousTotal > 0 else { return nil }
        return (total - previousTotal) / previousTotal * 100
    }

    private var rangeTitle: String {
        switch period {
        case .week, .custom:
            return "\(DateHelper.shortDate(range.start)) – \(DateHelper.shortDate(range.end.addingTimeInterval(-1)))"
        case .month:
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_Hant_TW")
            f.dateFormat = "yyyy 年 M 月"
            return f.string(from: anchor)
        }
    }

    // MARK: - Views

    private var picker: some View {
        Picker("區間", selection: $period) {
            ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var periodNavigator: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(rangeTitle).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(range.end >= Date())
        }
        .padding(.horizontal, 4)
    }

    private var customRange: some View {
        VStack(spacing: 8) {
            DatePicker("開始", selection: $customStart, displayedComponents: .date)
            DatePicker("結束", selection: $customEnd, displayedComponents: .date)
        }
        .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var summaryCard: some View {
        VStack(spacing: 8) {
            Text("本期總支出").font(.subheadline).foregroundStyle(.secondary)
            Text(Money.string(total))
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
            if let change = changePercent {
                Label(
                    String(format: "較上期 %@%.0f%%", change >= 0 ? "+" : "", change),
                    systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(change >= 0 ? Color(hex: "#FF453A") : Color(hex: "#34C759"))
            } else {
                Text("上期沒有紀錄").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Text("\(expenses.count) 筆")
                if !expenses.isEmpty {
                    Text("平均 \(Money.string(total / Double(expenses.count)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: 燒錢曲線

    private struct BurnPoint: Identifiable {
        let id = UUID()
        let day: Int
        let amount: Double
        let series: String
    }

    private var burnPoints: [BurnPoint] {
        let summary = BudgetService.summary(in: context, reference: anchor)
        let cumulative = BudgetService.cumulativeDailySpending(in: context, reference: anchor)
        var points: [BurnPoint] = cumulative.map { BurnPoint(day: $0.day, amount: $0.amount, series: "實際") }
        let days = summary.daysInMonth
        let idealPerDay = summary.idealDailyPace
        for day in stride(from: 1, through: days, by: 1) {
            points.append(BurnPoint(day: day, amount: idealPerDay * Double(day), series: "理想"))
        }
        return points
    }

    private var burnChart: some View {
        chartCard(title: "燒錢軌跡", subtitle: "實際 vs 理想消費速度") {
            Chart(burnPoints) { point in
                LineMark(
                    x: .value("日", point.day),
                    y: .value("累積", point.amount)
                )
                .foregroundStyle(by: .value("類型", point.series))
                .lineStyle(StrokeStyle(lineWidth: point.series == "理想" ? 2 : 3, dash: point.series == "理想" ? [5, 4] : []))
                .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale([
                "實際": Color(hex: "#0A84FF"),
                "理想": Color(hex: "#8E8E93")
            ])
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(Money.compact(amount)).font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 200)
        }
    }

    // MARK: 分類排行

    private struct CategorySlice: Identifiable {
        let id = UUID()
        let name: String
        let colorHex: String
        let amount: Double
    }

    private var categorySlices: [CategorySlice] {
        var totals: [String: (amount: Double, color: String)] = [:]
        for expense in expenses {
            let root = expense.category?.rootCategory
            let name = root?.name ?? "未分類"
            let color = root?.colorHex ?? "#8E8E93"
            let current = totals[name]?.amount ?? 0
            totals[name] = (current + expense.amount, color)
        }
        return totals
            .map { CategorySlice(name: $0.key, colorHex: $0.value.color, amount: $0.value.amount) }
            .sorted { $0.amount > $1.amount }
    }

    private var categoryChart: some View {
        chartCard(title: "分類排行", subtitle: "本期各分類花費") {
            if categorySlices.isEmpty {
                emptyHint
            } else {
                Chart(categorySlices) { slice in
                    BarMark(
                        x: .value("金額", slice.amount),
                        y: .value("分類", slice.name)
                    )
                    .foregroundStyle(Color(hex: slice.colorHex))
                    .annotation(position: .trailing) {
                        Text(Money.compact(slice.amount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .cornerRadius(4)
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(categorySlices.count) * 34 + 20)
            }
        }
    }

    // MARK: 每日趨勢

    private struct DayPoint: Identifiable {
        let id = UUID()
        let date: Date
        let amount: Double
    }

    private var dailyPoints: [DayPoint] {
        var totals: [Date: Double] = [:]
        for expense in expenses {
            let day = DateHelper.startOfDay(expense.date)
            totals[day, default: 0] += expense.amount
        }
        return totals.map { DayPoint(date: $0.key, amount: $0.value) }.sorted { $0.date < $1.date }
    }

    private var dailyChart: some View {
        chartCard(title: "每日花費", subtitle: "看得出哪幾天失控") {
            if dailyPoints.isEmpty {
                emptyHint
            } else {
                Chart(dailyPoints) { point in
                    BarMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value("金額", point.amount)
                    )
                    .foregroundStyle(Color(hex: "#0A84FF").gradient)
                    .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(Money.compact(amount)).font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
    }

    // MARK: 情緒佔比

    private struct EmotionSlice: Identifiable {
        let id = UUID()
        let name: String
        let colorHex: String
        let amount: Double
    }

    private var emotionSlices: [EmotionSlice] {
        var totals: [String: (amount: Double, color: String)] = [:]
        for expense in expenses {
            let name = expense.emotionTag?.name ?? "未標記"
            let color = expense.emotionTag?.colorHex ?? "#C7C7CC"
            let current = totals[name]?.amount ?? 0
            totals[name] = (current + expense.amount, color)
        }
        return totals
            .map { EmotionSlice(name: $0.key, colorHex: $0.value.color, amount: $0.value.amount) }
            .sorted { $0.amount > $1.amount }
    }

    private var emotionChart: some View {
        chartCard(title: "消費情緒", subtitle: "錢是為什麼花掉的") {
            if emotionSlices.isEmpty {
                emptyHint
            } else {
                VStack(spacing: 12) {
                    Chart(emotionSlices) { slice in
                        SectorMark(
                            angle: .value("金額", slice.amount),
                            innerRadius: .ratio(0.58),
                            angularInset: 1.5
                        )
                        .foregroundStyle(Color(hex: slice.colorHex))
                        .cornerRadius(4)
                    }
                    .frame(height: 180)

                    VStack(spacing: 6) {
                        ForEach(emotionSlices) { slice in
                            HStack(spacing: 8) {
                                Circle().fill(Color(hex: slice.colorHex)).frame(width: 10, height: 10)
                                Text(slice.name).font(.caption)
                                Spacer()
                                Text(Money.string(slice.amount)).font(.caption.monospacedDigit())
                                Text(String(format: "%.0f%%", total > 0 ? slice.amount / total * 100 : 0))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct SourceCount: Identifiable {
        let source: TransactionSource
        let count: Int
        var id: String { source.rawValue }
    }

    private var sourceCounts: [SourceCount] {
        Dictionary(grouping: expenses, by: { $0.source })
            .map { SourceCount(source: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private var sourceBreakdown: some View {
        chartCard(title: "記帳方式", subtitle: "哪種輸入方式你最常用") {
            if sourceCounts.isEmpty {
                emptyHint
            } else {
                VStack(spacing: 8) {
                    ForEach(sourceCounts) { item in
                        HStack {
                            Label(item.source.displayName, systemImage: item.source.iconName)
                                .font(.caption)
                            Spacer()
                            Text("\(item.count) 筆").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var emptyHint: some View {
        Text("這段期間沒有紀錄")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
    }

    private func chartCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func shift(_ step: Int) {
        let component: Calendar.Component = period == .week ? .weekOfYear : .month
        if let newDate = DateHelper.calendar.date(byAdding: component, value: step, to: anchor) {
            anchor = newDate
        }
    }
}
