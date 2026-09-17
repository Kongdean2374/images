import SwiftUI

/// 新增／編輯自訂運動。名稱、圖示、分類、強度四項，不用查 MET 表。
struct CustomSportEditor: View {
    /// nil 代表新增
    var editing: SportKind?
    let onDone: (SportKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = CustomSportStore.shared

    @State private var name = ""
    @State private var icon = "figure.mixed.cardio"
    @State private var category: SportCategory = .other
    @State private var intensity: CustomSportStore.Intensity = .moderate
    @State private var tracksDistance = false

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                nameSection
                iconSection
                categorySection
                intensitySection
                distanceSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(editing == nil ? "新增運動" : "編輯運動")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("儲存") { save() }
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { load() }
        }
        .preferredColorScheme(.dark)
    }

    private var previewSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.color(for: category).opacity(0.18))
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.color(for: category))
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(trimmedName.isEmpty ? "尚未命名" : trimmedName)
                        .font(.headline)
                        .foregroundStyle(trimmedName.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    Text("\(category.displayName)・\(intensity.displayName)・MET \(String(format: "%.1f", intensity.met))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var nameSection: some View {
        Section("名稱") {
            TextField("例如：拳擊有氧、獨木舟、滑雪", text: $name)
        }
    }

    private var iconSection: some View {
        Section("圖示") {
            LazyVGrid(columns: iconColumns, spacing: 10) {
                ForEach(CustomSportStore.iconChoices, id: \.self) { item in
                    Button {
                        icon = item
                        CueService.shared.impact(.soft)
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(icon == item
                                      ? Theme.color(for: category).opacity(0.28)
                                      : Color.white.opacity(0.06))
                            Image(systemName: item)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(icon == item ? Theme.color(for: category) : Theme.textSecondary)
                        }
                        .frame(height: 42)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var categorySection: some View {
        Section("分類") {
            Picker("分類", selection: $category) {
                ForEach(SportCategory.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var intensitySection: some View {
        Section {
            ForEach(CustomSportStore.Intensity.allCases) { level in
                Button {
                    intensity = level
                    CueService.shared.impact(.soft)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(level.detail)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        if intensity == level {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.mint)
                        }
                    }
                }
            }
        } header: {
            Text("強度")
        } footer: {
            Text("強度決定熱量估算的 MET 值。不確定就選「中等」，之後隨時能改。")
        }
    }

    private var distanceSection: some View {
        Section {
            Toggle("這是會移動的戶外運動", isOn: $tracksDistance)
        } footer: {
            Text(tracksDistance
                 ? "會多一個用 GPS 記錄軌跡的選項，適合單車、划船、滑雪這類會移動的項目。"
                 : "只提供計時記錄，適合球類、重訓、瑜伽這類在原地進行的項目。")
        }
    }

    private func load() {
        guard let editing else { return }
        name = editing.name
        icon = editing.icon
        category = editing.category
        intensity = CustomSportStore.Intensity.closest(to: editing.met)
        tracksDistance = editing.tracksDistance
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let editing {
            store.update(editing,
                         name: trimmedName,
                         icon: icon,
                         category: category,
                         intensity: intensity,
                         tracksDistance: tracksDistance)
            if let updated = SportCatalog.find(editing.id) { onDone(updated) }
        } else {
            let created = store.add(name: trimmedName,
                                    icon: icon,
                                    category: category,
                                    intensity: intensity,
                                    tracksDistance: tracksDistance)
            onDone(created)
        }
        dismiss()
    }
}
