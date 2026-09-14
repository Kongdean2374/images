import SwiftUI
import SwiftData
import UIKit

/// 記帳輸入 Sheet：手動輸入，也是 OCR 的「確認畫面」。
struct ExpenseEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SpendingCategory.sortOrder) private var allCategories: [SpendingCategory]
    @Query(sort: \EmotionTag.sortOrder) private var tags: [EmotionTag]

    /// 編輯既有紀錄時傳入
    var expense: Expense?
    /// OCR 辨識後帶進來的建議值
    var prefill: Prefill?
    /// 收據確認流程用：存完之後不關閉整個流程，交給上層決定
    var onSaved: (() -> Void)?
    /// 內嵌在別的畫面裡（收據確認流程）時不要自己再包一層 NavigationStack
    var embedded: Bool = false

    struct Prefill {
        var amount: Double?
        var date: Date?
        var merchant: String?
        var imageData: Data?
        var source: TransactionSource = .manual
        var rawLines: [String] = []
    }

    @State private var amountText: String = ""
    @State private var selectedParent: SpendingCategory?
    @State private var selectedChild: SpendingCategory?
    @State private var date: Date = Date()
    @State private var note: String = ""
    @State private var merchant: String = ""
    @State private var selectedTag: EmotionTag?
    @State private var receiptImageData: Data?
    @State private var showingRawText = false
    @FocusState private var amountFocused: Bool

    private var topLevelCategories: [SpendingCategory] {
        allCategories.filter { $0.parent == nil }
    }

    private var amount: Double { Double(amountText) ?? 0 }
    private var isEditing: Bool { expense != nil }

    var body: some View {
        if embedded {
            formContent
                .safeAreaInset(edge: .bottom) {
                    Button {
                        save()
                    } label: {
                        Text("確認並記下 \(Money.string(amount))")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(amount <= 0)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(.bar)
                }
        } else {
            NavigationStack {
                formContent
                    .navigationTitle(isEditing ? "編輯紀錄" : "記一筆")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("儲存") { save() }
                                .disabled(amount <= 0)
                                .fontWeight(.semibold)
                        }
                    }
            }
            .presentationDetents(isEditing ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var formContent: some View {
        Form {
                amountSection
                categorySection
                detailSection
                emotionSection
                if receiptImageData != nil || !(prefill?.rawLines.isEmpty ?? true) {
                    receiptSection
                }
                if isEditing {
                    Section {
                        Button(role: .destructive) { deleteExpense() } label: {
                            Label("刪除這筆紀錄", systemImage: "trash")
                        }
                    }
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { amountFocused = false }
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showingRawText) {
            RawTextView(lines: prefill?.rawLines ?? [])
        }
    }

    // MARK: - Sections

    private var amountSection: some View {
        Section("金額") {
            HStack {
                Text("$")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .focused($amountFocused)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AppSettings.quickAmounts, id: \.self) { value in
                        Button {
                            add(Double(value))
                        } label: {
                            Text("+\(value)")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                    Button {
                        amountText = ""
                    } label: {
                        Image(systemName: "delete.left")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var categorySection: some View {
        Section("分類") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                ForEach(topLevelCategories) { category in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedParent = category
                            selectedChild = nil
                        }
                    } label: {
                        VStack(spacing: 6) {
                            CategoryBadge(iconName: category.iconName, colorHex: category.colorHex, size: 42)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(Color.primary, lineWidth: selectedParent == category ? 2.5 : 0)
                                }
                            Text(category.name)
                                .font(.caption2)
                                .foregroundStyle(selectedParent == category ? .primary : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)

            if let parent = selectedParent, !parent.sortedChildren.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(parent.sortedChildren) { child in
                            Button {
                                selectedChild = (selectedChild == child) ? nil : child
                            } label: {
                                Text(child.name)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(selectedChild == child
                                                       ? Color(hex: parent.colorHex)
                                                       : Color(uiColor: .tertiarySystemFill))
                                    )
                                    .foregroundStyle(selectedChild == child ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var detailSection: some View {
        Section("細節") {
            DatePicker("日期", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
            TextField("備註（選填）", text: $note)
            TextField("店名（選填）", text: $merchant)
        }
    }

    private var emotionSection: some View {
        Section("消費情緒") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags) { tag in
                        Button {
                            selectedTag = (selectedTag == tag) ? nil : tag
                        } label: {
                            Label(tag.name, systemImage: tag.iconName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(selectedTag == tag
                                                   ? Color(hex: tag.colorHex)
                                                   : Color(uiColor: .tertiarySystemFill))
                                )
                                .foregroundStyle(selectedTag == tag ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var receiptSection: some View {
        Section("收據") {
            if let data = receiptImageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button(role: .destructive) {
                    receiptImageData = nil
                } label: {
                    Label("不保留收據照片", systemImage: "photo.badge.minus")
                }
            }
            if !(prefill?.rawLines.isEmpty ?? true) {
                Button {
                    showingRawText = true
                } label: {
                    Label("查看辨識到的原始文字", systemImage: "text.viewfinder")
                }
            }
        }
    }

    // MARK: - Logic

    private func load() {
        if let expense {
            amountText = expense.amount == expense.amount.rounded()
                ? String(Int(expense.amount))
                : String(expense.amount)
            date = expense.date
            note = expense.note ?? ""
            merchant = expense.merchant ?? ""
            selectedTag = expense.emotionTag
            receiptImageData = expense.receiptImageData
            if let category = expense.category {
                if let parent = category.parent {
                    selectedParent = parent
                    selectedChild = category
                } else {
                    selectedParent = category
                }
            }
        } else {
            if let prefill {
                if let amount = prefill.amount {
                    amountText = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.2f", amount)
                }
                if let prefillDate = prefill.date { date = prefillDate }
                if let prefillMerchant = prefill.merchant { merchant = prefillMerchant }
                receiptImageData = AppSettings.keepReceiptImage ? prefill.imageData : nil
            }
            if selectedParent == nil {
                selectedParent = topLevelCategories.first
            }
            if prefill == nil {
                amountFocused = true
            }
        }
    }

    private func add(_ value: Double) {
        amountText = String(Int(amount + value))
    }

    private func save() {
        guard amount > 0 else { return }
        let category = selectedChild ?? selectedParent
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)

        if let expense {
            expense.amount = amount
            expense.date = date
            expense.category = category
            expense.note = trimmedNote.isEmpty ? nil : trimmedNote
            expense.merchant = trimmedMerchant.isEmpty ? nil : trimmedMerchant
            expense.emotionTag = selectedTag
            expense.receiptImageData = receiptImageData
        } else {
            let new = Expense(
                amount: amount,
                date: date,
                category: category,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                emotionTag: selectedTag,
                source: prefill?.source ?? .manual,
                merchant: trimmedMerchant.isEmpty ? nil : trimmedMerchant,
                receiptImageData: receiptImageData
            )
            context.insert(new)
        }

        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)

        if let onSaved {
            onSaved()
        } else {
            dismiss()
        }
    }

    private func deleteExpense() {
        guard let expense else { return }
        context.delete(expense)
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
        dismiss()
    }
}

/// OCR 原始文字檢視，讓使用者自己對照
struct RawTextView: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.footnote, design: .monospaced))
            }
            .navigationTitle("辨識文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
