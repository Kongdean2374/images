import SwiftUI
import SwiftData

/// 首頁：從「花了多少」翻轉成「今天還能花多少」。
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var liveActivity: LiveActivityController

    @Binding var selection: RootView.Tab
    @Binding var presetCategory: SpendingCategory?
    @Binding var showingEditor: Bool

    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @Query private var settings: [BudgetSetting]
    @Query(sort: \SpendingCategory.sortOrder) private var categories: [SpendingCategory]

    @State private var summary = BudgetSummary()
    @State private var editingExpense: Expense?
    @State private var showingBudgetSetup = false

    private var recentExpenses: [Expense] { Array(allExpenses.prefix(6)) }

    private var todayTotal: Double {
        let start = DateHelper.startOfDay(Date())
        return allExpenses.filter { $0.date >= start }.reduce(0) { $0 + $1.amount }
    }

    private var weekDays: [(date: Date, amount: Double)] {
        let calendar = DateHelper.calendar
        let today = DateHelper.startOfDay(Date())
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let amount = allExpenses
                .filter { $0.date >= day && $0.date < next }
                .reduce(0) { $0 + $1.amount }
            return (date: day, amount: amount)
        }
    }

    private var topLevelCategories: [SpendingCategory] {
        categories.filter { $0.parent == nil }
    }

    private var spentProgress: Double {
        guard summary.spendable > 0 else { return 0 }
        return min(max(summary.variableSpent / summary.spendable, 0), 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    if summary.monthlyBudget <= 0 { setupPrompt }
                    todayRow
                    quickAddCard
                    weekCard
                    burnCard
                    recentCard
                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal)
                .padding(.top, 6)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("MoneyLeft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(monthLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingBudgetSetup = true
                    } label: {
                        Image(systemName: "target")
                    }
                    .accessibilityLabel("預算設定")
                }
            }
            .sheet(item: $editingExpense) { ExpenseEditorView(expense: $0) }
            .sheet(isPresented: $showingBudgetSetup) {
                NavigationStack { BudgetSettingsView() }
            }
            .onAppear(perform: reload)
            .onChange(of: allExpenses.count) { _, _ in reload() }
            .onChange(of: settings.first?.monthlyBudget) { _, _ in reload() }
        }
    }

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "M 月"
        return formatter.string(from: Date())
    }

    // MARK: - 主視覺

    private var heroCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.heroGradient(for: summary.burnLevel))
                .shadow(color: summary.burnLevel.color.opacity(0.3), radius: 14, y: 6)

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本月還可以花")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))

                    Text(Money.string(max(summary.remaining, 0)))
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())

                    if summary.remaining < 0 {
                        Label("已超支 \(Money.string(-summary.remaining))", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text("剩 \(summary.daysRemaining) 天 · 每天可花 \(Money.string(summary.dailyAllowance))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    Label(summary.burnLevel.label, systemImage: burnIcon)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.22)))
                        .foregroundStyle(.white)
                        .padding(.top, 2)
                }

                ZStack {
                    RingProgressView(progress: spentProgress, lineWidth: 11)
                    VStack(spacing: 1) {
                        Text("\(Int(spentProgress * 100))%")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        Text("已用")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(width: 86, height: 86)
            }
            .padding(20)
        }
    }

    private var burnIcon: String {
        switch summary.burnLevel {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .over: return "flame.fill"
        }
    }

    private var setupPrompt: some View {
        Button {
            showingBudgetSetup = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "target")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("先設定這個月的預算").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("設好之後才算得出「還能花多少」").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .card(padding: 12, corner: 18)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 今日 / 本週

    private var todayRow: some View {
        HStack(spacing: 12) {
            miniTile(
                title: "今日已花",
                value: Money.string(todayTotal),
                caption: summary.dailyAllowance > 0
                    ? "額度 \(Money.string(summary.dailyAllowance))"
                    : "尚未設定預算",
                tint: todayTotal > summary.dailyAllowance && summary.dailyAllowance > 0
                    ? Color(hex: "#FF453A") : .primary,
                icon: "sun.max.fill"
            )
            miniTile(
                title: "本月預估",
                value: Money.compact(summary.projectedMonthTotal),
                caption: summary.projectedRunOutDay.map { "預算撐到 \($0) 號" } ?? "在預算內",
                tint: summary.burnLevel.color,
                icon: "chart.line.uptrend.xyaxis"
            )
        }
    }

    private func miniTile(title: String, value: String, caption: String, tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, corner: 18)
    }

    // MARK: - 快速記帳

    private var quickAddCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "快速記帳", systemImage: "bolt.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(topLevelCategories.prefix(8)) { category in
                        Button {
                            presetCategory = category
                            showingEditor = true
                        } label: {
                            VStack(spacing: 6) {
                                CategoryBadge(iconName: category.iconName, colorHex: category.colorHex, size: 44)
                                Text(category.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .card()
    }

    // MARK: - 一週

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "最近七天", systemImage: "calendar") {
                Text(Money.string(weekDays.reduce(0) { $0 + $1.amount }))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            WeekBarStrip(days: weekDays, dailyAllowance: summary.dailyAllowance)
            if summary.dailyAllowance > 0 {
                Text("紅色代表那天超過每日額度 \(Money.string(summary.dailyAllowance))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    // MARK: - 燒錢速度

    private var burnCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "燒錢速度", systemImage: "speedometer") {
                Button {
                    selection = .stats
                } label: {
                    Text("完整報表")
                        .font(.caption.weight(.semibold))
                }
            }

            HStack(alignment: .center, spacing: 16) {
                BurnGaugeView(summary: summary)
                    .frame(width: 140)
                VStack(alignment: .leading, spacing: 10) {
                    labeled("理想日均", Money.string(summary.idealDailyPace))
                    labeled("實際日均", Money.string(summary.actualDailyPace), tint: summary.burnLevel.color)
                    labeled("今天該花到", Money.string(summary.idealSpentToDate))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    private func labeled(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    // MARK: - 最近紀錄

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "最近紀錄", systemImage: "clock.arrow.circlepath") {
                Button {
                    selection = .list
                } label: {
                    Text("看全部 \(allExpenses.count) 筆")
                        .font(.caption.weight(.semibold))
                }
            }

            if recentExpenses.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                    Text("還沒有紀錄，點下面中間的「記一筆」開始")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentExpenses) { expense in
                        Button { editingExpense = expense } label: { ExpenseRow(expense: expense) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { delete(expense) } label: {
                                    Label("刪除", systemImage: "trash")
                                }
                            }
                        if expense.persistentModelID != recentExpenses.last?.persistentModelID {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
        .card(padding: 14)
    }

    // MARK: - Actions

    private func reload() {
        summary = BudgetService.summary(in: context)
        BudgetService.refreshWidgetSnapshot(context: context)
    }

    private func delete(_ expense: Expense) {
        context.delete(expense)
        try? context.save()
        reload()
    }
}

struct ExpenseRow: View {
    let expense: Expense
    var showsTime: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            CategoryBadge(
                iconName: expense.category?.iconName ?? "questionmark.circle",
                colorHex: expense.category?.colorHex ?? "#8E8E93",
                size: 38
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(expense.category?.fullName ?? "未分類")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    Text(showsTime ? timeLabel : DateHelper.shortDate(expense.date))
                    if let note = expense.note, !note.isEmpty {
                        Text("·"); Text(note).lineLimit(1)
                    } else if let merchant = expense.merchant, !merchant.isEmpty {
                        Text("·"); Text(merchant).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Money.string(expense.amount))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    if let tag = expense.emotionTag {
                        Text(tag.name)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(hex: tag.colorHex).opacity(0.18)))
                            .foregroundStyle(Color(hex: tag.colorHex))
                    }
                    Image(systemName: expense.source.iconName)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: expense.date)
    }
}
