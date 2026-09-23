import SwiftUI
import ChaiNetCore

/// Pick any combination of items; run once or save as a Test Profile.
struct CustomTestView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selected: Set<TestItem> = TestProfile.quickSpeed.items
    @State private var profileName = ""
    @State private var showSave = false

    var body: some View {
        List {
            Section("設定檔") {
                ForEach(settings.settings.allProfiles) { profile in
                    Button {
                        selected = profile.items
                    } label: {
                        HStack {
                            Label(profile.name, systemImage: profile.symbolName)
                            Spacer()
                            Text("\(profile.items.count) 項").font(.caption).foregroundStyle(Theme.textSecondary)
                            if profile.items == selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
                .onDelete(perform: deleteProfiles)
            }
            Section {
                ForEach(TestItem.allCases) { item in
                    Toggle(isOn: binding(item)) { Label(item.displayName, systemImage: item.symbolName) }
                }
            } header: {
                Text("測試項目")
            } footer: {
                Text("預估數據用量約 \(Int(TestProfile(name: "", symbolName: "", items: selected).estimatedDataMB)) MB（依網速與時間設定而定）。")
            }
            Section {
                NavigationLink {
                    ToolRunView(title: "自訂測試", items: selected)
                } label: {
                    Label("開始測試", systemImage: "play.fill").fontWeight(.semibold)
                }
                .disabled(selected.isEmpty)
                Button { showSave = true } label: { Label("儲存為設定檔", systemImage: "square.and.arrow.down") }
                    .disabled(selected.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("自訂測試")
        .alert("儲存設定檔", isPresented: $showSave) {
            TextField("名稱", text: $profileName)
            Button("儲存") { save() }
            Button("取消", role: .cancel) {}
        }
    }

    private func binding(_ item: TestItem) -> Binding<Bool> {
        Binding(get: { selected.contains(item) }, set: { on in
            if on { selected.insert(item) } else { selected.remove(item) }
        })
    }

    private func save() {
        let name = profileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        settings.settings.savedProfiles.append(TestProfile(name: name, symbolName: "star", items: selected))
        profileName = ""
    }

    private func deleteProfiles(at offsets: IndexSet) {
        let all = settings.settings.allProfiles
        let ids = Set(offsets.map { all[$0] }.filter { !$0.isBuiltIn }.map(\.id))
        settings.settings.savedProfiles.removeAll { ids.contains($0.id) }
    }
}
