import SwiftUI
import SwiftData

/// 預算設定：月預算 + 固定支出清單（計劃書 §3）
struct BudgetSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var settings: [BudgetSetting]

    @State private var budgetText: String = ""
    @State private var showingFixedEditor = false
    @State private var editingFixed: FixedExpense?

    private var setting: BudgetSetting? { settings.first }

    private var budget: Double { Double(budgetText) ?? 0 }

    private var fixedTotal: Double { setting?.fixedExpenseTotal ?? 0 }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("$").foregroundStyle(.secondary)
                    TextField("0", text: $budgetText)
                        .keyboardType(.numberPad)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .onChange(of: budgetText) { _, _ in saveBudget() }
                }
            } header: {
                Text("每月預算")
            } footer: {
                Text("這是你這個月「全部」可以動用的錢，包含下面的固定支出。")
            }

            Section {
                if let setting, !setting.sortedFixedExpenses.isEmpty {
                    ForEach(setting.sortedFixedExpenses) { item in
                        Button {
                            editingFixed = item
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text("每月 \(item.dueDay) 號").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Money.string(item.amount))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteFixed)
                } else {
                    Text("還沒有固定支出").font(.footnote).foregroundStyle(.secondary)
                }

                Button {
                    editingFixed = nil
                    showingFixedEditor = true
                } label: {
                    Label("新增固定支出", systemImage: "plus")
                }
            } header: {
                Text("固定支出")
            } footer: {
                Text("房租、保險、訂閱…這些會先從預算裡扣掉，不會出現在每日可花額度裡。")
            }

            Section("試算") {
                LabeledContent("月預算", value: Money.string(budget))
                LabeledContent("固定支出", value: "− " + Money.string(fixedTotal))
                LabeledContent("可自由支配") {
                    Text(Money.string(max(budget - fixedTotal, 0)))
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
                LabeledContent("平均每天") {
                    Text(Money.string(max(budget - fixedTotal, 0) / Double(DateHelper.daysInMonth())))
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle("預算設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    saveBudget()
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showingFixedEditor) {
            FixedExpenseEditor(fixedExpense: nil)
        }
        .sheet(item: $editingFixed) { item in
            FixedExpenseEditor(fixedExpense: item)
        }
        .onAppear {
            let current = BudgetService.currentSetting(in: context)
            budgetText = current.monthlyBudget > 0 ? String(Int(current.monthlyBudget)) : ""
        }
    }

    private func saveBudget() {
        let current = BudgetService.currentSetting(in: context)
        current.monthlyBudget = budget
        current.updatedAt = Date()
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
    }

    private func deleteFixed(at offsets: IndexSet) {
        guard let setting else { return }
        let items = setting.sortedFixedExpenses
        for index in offsets where index < items.count {
            context.delete(items[index])
        }
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
    }
}

struct FixedExpenseEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var fixedExpense: FixedExpense?

    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var dueDay: Int = 1

    var body: some View {
        NavigationStack {
            Form {
                TextField("名稱（例如：房租）", text: $name)
                HStack {
                    Text("$").foregroundStyle(.secondary)
                    TextField("金額", text: $amountText)
                        .keyboardType(.numberPad)
                        .monospacedDigit()
                }
                Picker("每月扣款日", selection: $dueDay) {
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day) 號").tag(day)
                    }
                }
            }
            .navigationTitle(fixedExpense == nil ? "新增固定支出" : "編輯固定支出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (Double(amountText) ?? 0) <= 0)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let fixedExpense {
                    name = fixedExpense.name
                    amountText = String(Int(fixedExpense.amount))
                    dueDay = fixedExpense.dueDay
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let amount = Double(amountText) ?? 0
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard amount > 0, !trimmed.isEmpty else { return }

        let setting = BudgetService.currentSetting(in: context)
        if let fixedExpense {
            fixedExpense.name = trimmed
            fixedExpense.amount = amount
            fixedExpense.dueDay = dueDay
        } else {
            let new = FixedExpense(name: trimmed, amount: amount, dueDay: dueDay)
            new.budget = setting
            context.insert(new)
        }
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
        dismiss()
    }
}
