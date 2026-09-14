import SwiftUI
import SwiftData
import Charts

/// 點某個分類就能看它的趨勢與所有紀錄
struct CategoryDetailView: View {
    let category: SpendingCategory

    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @State private var editingExpense: Expense?

    private var expenses: [Expense] {
        allExpenses.filter { $0.category?.rootCategory.persistentModelID == category.persistentModelID }
    }

    private var thisMonth: [Expense] {
        let interval = DateHelper.monthInterval()
        return expenses.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    private var monthTotal: Double { thisMonth.reduce(0) { $0 + $1.amount } }

    private struct MonthPoint: Identifiable {
        let id = UUID()
        let label: String
        let amount: Double
    }

    /// 最近六個月
    private var monthlyTrend: [MonthPoint] {
        let calendar = DateHelper.calendar
        return (0..<6).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: Date()) else { return nil }
            let interval = DateHelper.monthInterval(for: date)
            let amount = expenses
                .filter { $0.date >= interval.start && $0.date < interval.end }
                .reduce(0) { $0 + $1.amount }
            let formatter = DateFormatter()
            formatter.dateFormat = "M月"
            return MonthPoint(label: formatter.string(from: date), amount: amount)
        }
    }

    private struct SubTotal: Identifiable {
        let id = UUID()
        let name: String
        let amount: Double
    }

    private var subTotals: [SubTotal] {
        var totals: [String: Double] = [:]
        for expense in thisMonth {
            let name = expense.category?.parent == nil ? "未細分" : (expense.category?.name ?? "未細分")
            totals[name, default: 0] += expense.amount
        }
        return totals.map { SubTotal(name: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                trendCard
                if subTotals.count > 1 { subCard }
                listCard
                Color.clear.frame(height: 12)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingExpense) { ExpenseEditorView(expense: $0) }
    }

    private var header: some View {
        VStack(spacing: 8) {
            CategoryBadge(iconName: category.iconName, colorHex: category.colorHex, size: 54)
            Text(Money.string(monthTotal))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .monospacedDigit()
            Text("本月 \(thisMonth.count) 筆")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !thisMonth.isEmpty {
                Text("平均每筆 \(Money.string(monthTotal / Double(thisMonth.count)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "最近六個月", systemImage: "chart.bar.fill")
            Chart(monthlyTrend) { point in
                BarMark(
                    x: .value("月份", point.label),
                    y: .value("金額", point.amount)
                )
                .foregroundStyle(Color(hex: category.colorHex).gradient)
                .cornerRadius(4)
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
            .frame(height: 160)
        }
        .card()
    }

    private var subCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "本月子分類", systemImage: "square.grid.2x2")
            ForEach(subTotals) { item in
                HStack {
                    Text(item.name).font(.subheadline)
                    Spacer()
                    Text(Money.string(item.amount))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", monthTotal > 0 ? item.amount / monthTotal * 100 : 0))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .card()
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "本月紀錄", systemImage: "list.bullet")
            if thisMonth.isEmpty {
                Text("這個月還沒有這個分類的紀錄")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ForEach(thisMonth) { expense in
                    Button { editingExpense = expense } label: {
                        ExpenseRow(expense: expense)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .card(padding: 14)
    }
}
