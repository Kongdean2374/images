import SwiftUI
import SwiftData

/// 分類管理（計劃書 §6）：新增／刪除／改名、自訂圖示與顏色、支援子分類。
struct CategoryManagerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SpendingCategory.sortOrder) private var categories: [SpendingCategory]

    @State private var editorTarget: EditorTarget?
    @State private var expanded: Set<String> = []

    private struct EditorTarget: Identifiable {
        var id = UUID()
        var category: SpendingCategory?
        var parent: SpendingCategory?
    }

    private var topLevel: [SpendingCategory] {
        categories.filter { $0.parent == nil }
    }

    var body: some View {
        List {
            Section {
                ForEach(topLevel) { category in
                    row(for: category)
                    if expanded.contains(category.name) {
                        ForEach(category.sortedChildren) { child in
                            childRow(child, parent: category)
                        }
                        Button {
                            editorTarget = EditorTarget(category: nil, parent: category)
                        } label: {
                            Label("新增「\(category.name)」的子分類", systemImage: "plus.circle")
                                .font(.caption)
                        }
                        .padding(.leading, 44)
                    }
                }
                .onMove(perform: move)
            } header: {
                Text("分類")
            } footer: {
                Text("刪除分類時，該分類底下的紀錄會變成「未分類」，不會被刪掉。")
            }

            Section {
                Button {
                    editorTarget = EditorTarget(category: nil, parent: nil)
                } label: {
                    Label("新增分類", systemImage: "plus")
                }
            }
        }
        .navigationTitle("分類管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editorTarget) { target in
            CategoryEditorView(category: target.category, parent: target.parent)
        }
    }

    private func row(for category: SpendingCategory) -> some View {
        HStack(spacing: 12) {
            CategoryBadge(iconName: category.iconName, colorHex: category.colorHex, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name).font(.body)
                if !category.sortedChildren.isEmpty {
                    Text("\(category.sortedChildren.count) 個子分類")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                withAnimation {
                    if expanded.contains(category.name) {
                        expanded.remove(category.name)
                    } else {
                        expanded.insert(category.name)
                    }
                }
            } label: {
                Image(systemName: expanded.contains(category.name) ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { editorTarget = EditorTarget(category: category, parent: nil) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(category) } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    private func childRow(_ child: SpendingCategory, parent: SpendingCategory) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: child.colorHex)).frame(width: 8, height: 8)
            Text(child.name).font(.callout)
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.leading, 44)
        .contentShape(Rectangle())
        .onTapGesture { editorTarget = EditorTarget(category: child, parent: parent) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(child) } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var items = topLevel
        items.move(fromOffsets: source, toOffset: destination)
        for (index, item) in items.enumerated() {
            item.sortOrder = index
        }
        try? context.save()
    }

    private func delete(_ category: SpendingCategory) {
        // 子分類跟著刪；底下的紀錄改成未分類（deleteRule 已設定 nullify）
        context.delete(category)
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
    }
}

/// 新增／編輯分類
struct CategoryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.sortOrder) private var allCategories: [SpendingCategory]

    var category: SpendingCategory?
    var parent: SpendingCategory?

    @State private var name: String = ""
    @State private var iconName: String = "tag.fill"
    @State private var colorHex: String = "#0A84FF"

    static let icons: [String] = [
        "fork.knife", "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill", "carrot.fill",
        "tram.fill", "car.fill", "fuelpump.fill", "bicycle", "airplane",
        "cart.fill", "bag.fill", "house.fill", "lightbulb.fill", "drop.fill",
        "gamecontroller.fill", "film.fill", "music.note", "book.fill", "ticket.fill",
        "tshirt.fill", "shoe.fill", "scissors", "sparkles",
        "cross.case.fill", "pills.fill", "stethoscope", "heart.fill",
        "antenna.radiowaves.left.and.right", "iphone", "wifi", "creditcard.fill",
        "pawprint.fill", "gift.fill", "graduationcap.fill", "briefcase.fill",
        "wrench.and.screwdriver.fill", "ellipsis.circle.fill", "tag.fill", "questionmark.circle"
    ]

    private var isEditing: Bool { category != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        CategoryBadge(iconName: iconName, colorHex: colorHex, size: 52)
                        TextField("分類名稱", text: $name)
                            .font(.title3)
                    }
                    if let parent {
                        Text("屬於「\(parent.name)」的子分類")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("顏色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Color.palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(height: 34)
                                .overlay {
                                    if hex == colorHex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("圖示") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.icons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.system(size: 18))
                                .frame(height: 34)
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(icon == iconName ? Color.white : Color.primary)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(icon == iconName ? Color(hex: colorHex) : Color(uiColor: .tertiarySystemFill))
                                )
                                .onTapGesture { iconName = icon }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(isEditing ? "編輯分類" : (parent == nil ? "新增分類" : "新增子分類"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let category {
                    name = category.name
                    iconName = category.iconName
                    colorHex = category.colorHex
                } else if let parent {
                    iconName = parent.iconName
                    colorHex = parent.colorHex
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let category {
            category.name = trimmed
            category.iconName = iconName
            category.colorHex = colorHex
        } else {
            let siblings = parent?.sortedChildren.count ?? allCategories.filter { $0.parent == nil }.count
            let new = SpendingCategory(
                name: trimmed,
                iconName: iconName,
                colorHex: colorHex,
                isDefault: false,
                sortOrder: siblings,
                parent: parent
            )
            context.insert(new)
        }
        try? context.save()
        dismiss()
    }
}
