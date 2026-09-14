import SwiftUI
import SwiftData

/// 明細頁：搜尋、篩選、依日分組，快速定位任何一筆紀錄。
struct ExpenseListView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @Query(sort: \SpendingCategory.sortOrder) private var categories: [SpendingCategory]
    @Query(sort: \EmotionTag.sortOrder) private var tags: [EmotionTag]

    @State private var searchText = ""
    @State private var anchor = Date()
    @State private var scope: Scope = .month
    @State private var categoryFilter: SpendingCategory?
    @State private var tagFilter: EmotionTag?
    @State private var sourceFilter: TransactionSource?
    @State private var editingExpense: Expense?

    enum Scope: String, CaseIterable, Identifiable {
        case month = "本月"
        case all = "全部"
        var id: String { rawValue }
    }

    // MARK: - 資料

    private var range: DateInterval? {
        scope == .month ? DateHelper.monthInterval(for: anchor) : nil
    }

    private var filtered: [Expense] {
        allExpenses.filter { expense in
            if let range, !(expense.date >= range.start && expense.date < range.end) { return false }
            if let categoryFilter, expense.category?.rootCategory.persistentModelID != categoryFilter.persistentModelID { return false }
            if let tagFilter, expense.emotionTag?.persistentModelID != tagFilter.persistentModelID { return false }
            if let sourceFilter, expense.source != sourceFilter { return false }
            if !searchText.isEmpty {
                let keyword = searchText.lowercased()
                let haystack = [
                    expense.category?.fullName ?? "",
                    expense.note ?? "",
                    expense.merchant ?? "",
                    expense.emotionTag?.name ?? "",
                    String(Int(expense.amount))
                ].joined(separator: " ").lowercased()
                if !haystack.contains(keyword) { return false }
            }
            return true
        }
    }

    private struct DayGroup: Identifiable {
        let date: Date
        let expenses: [Expense]
        var id: Date { date }
        var total: Double { expenses.reduce(0) { $0 + $1.amount } }
    }

    private var groups: [DayGroup] {
        let grouped = Dictionary(grouping: filtered) { DateHelper.startOfDay($0.date) }
        return grouped
            .map { DayGroup(date: $0.key, expenses: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    private var total: Double { filtered.reduce(0) { $0 + $1.amount } }

    private var hasActiveFilter: Bool {
        categoryFilter != nil || tagFilter != nil || sourceFilter != nil || !searchText.isEmpty
    }

    // MARK: - View

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if groups.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.expenses) { expense in
                                    Button { editingExpense = expense } label: {
                                        ExpenseRow(expense: expense, showsTime: true)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { delete(expense) } label: {
                                            Label("刪除", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(DateHelper.mediumDate(group.date))
                                    Spacer()
                                    Text(Money.string(group.total)).monospacedDigit()
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("明細")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋分類、備註、店名、金額")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("範圍", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if hasActiveFilter {
                            Button(role: .destructive) { clearFilters() } label: {
                                Label("清除所有篩選", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(item: $editingExpense) { ExpenseEditorView(expense: $0) }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if scope == .month {
                HStack {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(monthTitle).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                        .disabled((range?.end ?? Date()) >= Date())
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 14) {
                summaryPill(title: "筆數", value: "\(filtered.count)")
                summaryPill(title: "合計", value: Money.string(total))
                if filtered.count > 0 {
                    summaryPill(title: "平均", value: Money.string(total / Double(filtered.count)))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Button("全部分類") { categoryFilter = nil }
                        ForEach(categories.filter { $0.parent == nil }) { category in
                            Button(category.name) { categoryFilter = category }
                        }
                    } label: {
                        chipLabel(
                            title: categoryFilter?.name ?? "分類",
                            icon: "square.grid.2x2",
                            active: categoryFilter != nil,
                            tint: categoryFilter.map { Color(hex: $0.colorHex) } ?? Theme.accent
                        )
                    }

                    Menu {
                        Button("全部情緒") { tagFilter = nil }
                        ForEach(tags) { tag in
                            Button(tag.name) { tagFilter = tag }
                        }
                    } label: {
                        chipLabel(
                            title: tagFilter?.name ?? "情緒",
                            icon: "heart.fill",
                            active: tagFilter != nil,
                            tint: tagFilter.map { Color(hex: $0.colorHex) } ?? Theme.accent
                        )
                    }

                    Menu {
                        Button("全部來源") { sourceFilter = nil }
                        ForEach(TransactionSource.allCases) { source in
                            Button(source.displayName) { sourceFilter = source }
                        }
                    } label: {
                        chipLabel(
                            title: sourceFilter?.displayName ?? "來源",
                            icon: "tray.and.arrow.down",
                            active: sourceFilter != nil
                        )
                    }

                    if hasActiveFilter {
                        FilterChip(title: "清除", systemImage: "xmark", isActive: false, tint: .gray) {
                            clearFilters()
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func chipLabel(title: String, icon: String, active: Bool, tint: Color = Theme.accent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
            Text(title).font(.caption.weight(.medium))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(active ? tint : Color(uiColor: .tertiarySystemFill)))
        .foregroundStyle(active ? .white : .primary)
    }

    private func summaryPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: hasActiveFilter ? "magnifyingglass" : "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(hasActiveFilter ? "沒有符合條件的紀錄" : "這個月還沒有紀錄")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if hasActiveFilter {
                Button("清除篩選") { clearFilters() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter.string(from: anchor)
    }

    // MARK: - Actions

    private func shiftMonth(_ step: Int) {
        if let date = DateHelper.calendar.date(byAdding: .month, value: step, to: anchor) {
            anchor = date
        }
    }

    private func clearFilters() {
        categoryFilter = nil
        tagFilter = nil
        sourceFilter = nil
        searchText = ""
    }

    private func delete(_ expense: Expense) {
        context.delete(expense)
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
    }
}
