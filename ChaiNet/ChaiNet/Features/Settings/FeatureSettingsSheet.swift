import SwiftUI
import ChaiNetCore

/// ⚙︎ on each feature: overrides for this feature only. Anything left on "通用設定" follows the
/// global settings in the Settings tab.
struct FeatureSettingsSheet: View {
    let featureID: String
    let title: String
    @Environment(SettingsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var global: AppSettings { store.settings }
    private var effective: AppSettings { store.settings.effective(for: featureID) }

    var body: some View {
        Form {
            Section {
                Text("未修改的項目沿用「設定」分頁的通用設定。").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Section {
                picker("測試時間", \.testDuration, TestDurationSetting.allCases, global.testDuration.displayName) { $0.displayName }
            } header: {
                Text("時間")
            } footer: {
                Text("固定時間會套用到每一個項目（Ping、封包遺失、下載、上傳、交叉驗證、IPv4/IPv6、介面比較、監測），樣本越多結果越穩定；「自動」使用各項目建議時長，下載 / 上傳在速度穩定後自動結束。")
            }
            Section("連線") {
                picker("平行連線", \.parallelConnections, ParallelConnectionsSetting.allCases, global.parallelConnections.displayName) { $0.displayName }
                picker("IP 協定", \.ipPreference, IPFamilyPreference.allCases, global.ipPreference.displayName) { $0.displayName }
                picker("流量使用", \.trafficUsage, TrafficUsageSetting.allCases, global.trafficUsage.displayName) { $0.displayName }
            }
            Section {
                picker("伺服器", \.serverSelection, ServerSelectionMode.allCases, global.serverSelection.displayName) { $0.displayName }
                ServerModeDetail(settings: effective, allServers: store.allServers,
                                 manualID: overrideBinding(\.manualServerID, fallback: global.manualServerID),
                                 selectedIDs: overrideBinding(\.selectedServerIDs, fallback: global.selectedServerIDs),
                                 autoCount: overrideBinding(\.autoServerCount, fallback: global.autoServerCount))
                Toggle("加入多端點驗證", isOn: overrideBinding(\.multiPointValidation, fallback: global.multiPointValidation))
            } header: {
                Text("伺服器 / 多點測試")
            } footer: {
                Text("多台伺服器時，Ping / 封包遺失 / 下載 / 上傳會在每台伺服器分別量測並比較；多端點驗證會另外量測 Cloudflare、Google、Quad9、Apple 的延遲與遺失。")
            }
            Section {
                Button("全部恢復為通用設定", role: .destructive) { store.settings.overrides[featureID] = nil }
                    .disabled(store.settings.overrides[featureID] == nil)
            }
        }
        .navigationTitle("\(title) 設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("完成") { dismiss() } }
    }

    // MARK: Bindings

    private func overrides() -> RunOverrides { store.settings.overrides[featureID] ?? RunOverrides() }

    private func write(_ o: RunOverrides) { store.settings.overrides[featureID] = o.isEmpty ? nil : o }

    private func optionalBinding<T>(_ key: WritableKeyPath<RunOverrides, T?>) -> Binding<T?> {
        Binding(get: { overrides()[keyPath: key] }, set: { v in var o = overrides(); o[keyPath: key] = v; write(o) })
    }

    /// Non-optional binding that stores an override on first change.
    private func overrideBinding<T>(_ key: WritableKeyPath<RunOverrides, T?>, fallback: T) -> Binding<T> {
        Binding(get: { overrides()[keyPath: key] ?? fallback }, set: { v in var o = overrides(); o[keyPath: key] = v; write(o) })
    }

    private func picker<T: Hashable>(_ label: String, _ key: WritableKeyPath<RunOverrides, T?>, _ options: [T], _ globalName: String,
                                     name: @escaping (T) -> String) -> some View {
        Picker(label, selection: optionalBinding(key)) {
            Text("通用設定（\(globalName)）").tag(T?.none)
            ForEach(options, id: \.self) { Text(name($0)).tag(T?.some($0)) }
        }
    }
}

/// Extra controls for the chosen server mode (shared by global and per-feature settings).
struct ServerModeDetail: View {
    let settings: AppSettings
    let allServers: [ServerDescriptor]
    @Binding var manualID: String?
    @Binding var selectedIDs: [String]
    @Binding var autoCount: Int

    var body: some View {
        switch settings.serverSelection {
        case .automatic:
            EmptyView()
        case .manual:
            Picker("指定伺服器", selection: $manualID) {
                ForEach(allServers) { Text($0.name).tag(String?.some($0.id)) }
            }
        case .multiple:
            ForEach(allServers) { server in
                Button {
                    if let i = selectedIDs.firstIndex(of: server.id) { selectedIDs.remove(at: i) } else { selectedIDs.append(server.id) }
                } label: {
                    HStack {
                        Image(systemName: selectedIDs.contains(server.id) ? "checkmark.square.fill" : "square").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(server.name).foregroundStyle(Theme.textPrimary)
                            Text(server.location).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if selectedIDs.first == server.id { Badge(text: "主要", color: Theme.accent) }
                    }
                }
            }
            if allServers.count < 2 {
                Text("目前只有 1 台伺服器；請在「設定 › 伺服器 › 管理伺服器」加入自架 ChaiNet 伺服器。")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        case .autoMultiple:
            Stepper("自動選取延遲最低的 \(autoCount) 台", value: $autoCount, in: 2...6)
            if allServers.count < 2 {
                Text("目前只有 1 台伺服器；加入自架伺服器後即可自動比較多台。").font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }
}

/// Adds the ⚙︎ button + sheet to a feature screen.
struct FeatureSettingsButton: ViewModifier {
    let featureID: String
    let title: String
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { show = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("\(title) 專屬設定")
                }
            }
            .sheet(isPresented: $show) {
                NavigationStack { FeatureSettingsSheet(featureID: featureID, title: title) }
            }
    }
}

extension View {
    func featureSettings(_ featureID: String, title: String) -> some View {
        modifier(FeatureSettingsButton(featureID: featureID, title: title))
    }
}
