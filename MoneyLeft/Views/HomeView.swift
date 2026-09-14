import SwiftUI
import SwiftData

/// 首頁：從「花了多少」翻轉成「今天還能花多少」。
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var liveActivity: LiveActivityController
    @Binding var showingEditor: Bool
    @Binding var showingReceiptFlow: Bool

    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @Query private var settings: [BudgetSetting]

    @State private var summary: BudgetSummary = BudgetSummary()
    @State private var editingExpense: Expense?
    @State private var showingBudgetSetup = false

    private var recentExpenses: [Expense] { Array(allExpenses.prefix(12)) }

    private var todayTotal: Double {
        let start = DateHelper.startOfDay(Date())
        return allExpenses.filter { $0.date >= start }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    remainingCard
                    if summary.monthlyBudget <= 0 {
                        setupPrompt
                    }
                    quickActions
                    burnCard
                    recentList
                    Color.clear.frame(height: 72)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("MoneyLeft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingReceiptFlow = true
                    } label: {
                        Image(systemName: "doc.text.viewfinder")
                    }
                    .accessibilityLabel("掃描收據")
                }
            }
            .overlay(alignment: .bottomTrailing) { floatingButton }
            .sheet(item: $editingExpense) { expense in
                ExpenseEditorView(expense: expense)
            }
            .sheet(isPresented: $showingBudgetSetup) {
                NavigationStack { BudgetSettingsView() }
            }
            .onAppear(perform: reload)
            .onChange(of: allExpenses.count) { _, _ in reload() }
            .onChange(of: settings.first?.monthlyBudget) { _, _ in reload() }
        }
    }

    // MARK: - Sections

    private var remainingCard: some View {
        VStack(spacing: 8) {
            Text("本月還可以花")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(Money.string(max(summary.remaining, 0)))
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(summary.remaining < 0 ? Color(hex: "#FF453A") : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())

            if summary.remaining < 0 {
                Text("已超支 \(Money.string(-summary.remaining))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(hex: "#FF453A"))
            } else {
                Text("距離月底還有 \(summary.daysRemaining) 天，平均每天可花 \(Money.string(summary.dailyAllowance))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView(value: min(max(summary.variableSpent / max(summary.spendable, 1), 0), 1))
                .tint(summary.burnLevel.color)
                .padding(.top, 4)

            HStack {
                Text("已花 \(Money.string(summary.variableSpent))")
                Spacer()
                Text("可支配 \(Money.string(summary.spendable))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var setupPrompt: some View {
        Button {
            showingBudgetSetup = true
        } label: {
            HStack {
                Image(systemName: "target")
                VStack(alignment: .leading, spacing: 2) {
                    Text("先設定這個月的預算").font(.subheadline.weight(.semibold))
                    Text("設好之後才算得出「還能花多少」").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            StatTile(title: "今日已花", value: Money.string(todayTotal), caption: "每日額度 \(Money.string(summary.dailyAllowance))")
            StatTile(
                title: "本月預估",
                value: Money.compact(summary.projectedMonthTotal),
                caption: summary.projectedRunOutDay.map { "預算撐到 \($0) 號" } ?? "在預算內",
                tint: summary.burnLevel.color
            )
        }
    }

    private var burnCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("燒錢速度", systemImage: "speedometer").font(.headline)
                Spacer()
                liveActivityButton
            }

            HStack(alignment: .center, spacing: 18) {
                BurnGaugeView(summary: summary)
                    .frame(width: 150)
                VStack(alignment: .leading, spacing: 10) {
                    labeled("理想日均", Money.string(summary.idealDailyPace))
                    labeled("實際日均", Money.string(summary.actualDailyPace), tint: summary.burnLevel.color)
                    labeled("該花到", Money.string(summary.idealSpentToDate))
                }
            }

            Text("理想速度是把可支配預算平均攤到整個月；紅色代表照這個速度月底會超支。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var liveActivityButton: some View {
        Button {
            if liveActivity.isActive {
                liveActivity.end()
            } else {
                liveActivity.start(context: context)
            }
        } label: {
            Label(
                liveActivity.isActive ? "結束動態島" : "動態島記帳",
                systemImage: liveActivity.isActive ? "stop.circle.fill" : "capsule.portrait"
            )
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private func labeled(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold)).foregroundStyle(tint).monospacedDigit()
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近紀錄").font(.headline)
                Spacer()
                if !allExpenses.isEmpty {
                    Text("\(allExpenses.count) 筆").font(.caption).foregroundStyle(.secondary)
                }
            }

            if recentExpenses.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                    Text("還沒有紀錄，點右下角 + 記第一筆").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentExpenses) { expense in
                        Button {
                            editingExpense = expense
                        } label: {
                            ExpenseRow(expense: expense)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { delete(expense) } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                        if expense.persistentModelID != recentExpenses.last?.persistentModelID {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var floatingButton: some View {
        Button {
            showingEditor = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color(hex: "#0A84FF"), in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .accessibilityLabel("新增一筆支出")
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

    var body: some View {
        HStack(spacing: 12) {
            CategoryBadge(
                iconName: expense.category?.iconName ?? "questionmark.circle",
                colorHex: expense.category?.colorHex ?? "#8E8E93"
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(expense.category?.fullName ?? "未分類")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(DateHelper.shortDate(expense.date))
                    if let note = expense.note, !note.isEmpty {
                        Text("·")
                        Text(note).lineLimit(1)
                    } else if let merchant = expense.merchant, !merchant.isEmpty {
                        Text("·")
                        Text(merchant).lineLimit(1)
                    }
                    if let tag = expense.emotionTag {
                        Text("·")
                        Text(tag.name).foregroundStyle(Color(hex: tag.colorHex))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Money.string(expense.amount))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Image(systemName: expense.source.iconName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
