import SwiftUI
import CoreLocation
import ChaiNetCore

struct SettingsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var store
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("速度單位") {
                Picker("主單位", selection: $store.settings.primarySpeedUnit) {
                    ForEach(SpeedUnit.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("輔助單位", selection: $store.settings.secondarySpeedUnit) {
                    Text("不顯示").tag(SpeedUnit?.none)
                    ForEach(SpeedUnit.allCases.filter { $0 != .auto }) { Text($0.displayName).tag(SpeedUnit?.some($0)) }
                }
                LabeledContent("預覽", value: SpeedFormatter.dual(mbps: 524, primary: store.settings.primarySpeedUnit, secondary: store.settings.secondarySpeedUnit))
            }
            Section("圖表") {
                Picker("圖表樣式", selection: $store.settings.chartStyle) {
                    ForEach(ChartStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("測試時間", selection: $store.settings.testDuration) {
                    ForEach(TestDurationSetting.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("平行連線", selection: $store.settings.parallelConnections) {
                    ForEach(ParallelConnectionsSetting.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("流量使用", selection: $store.settings.trafficUsage) {
                    ForEach(TrafficUsageSetting.allCases) { Text($0.displayName).tag($0) }
                }
                if store.settings.trafficUsage == .capped {
                    Stepper("每次上限 \(Int(store.settings.maxMegabytesPerTest)) MB", value: $store.settings.maxMegabytesPerTest, in: 50...5000, step: 50)
                }
                Picker("IP 協定", selection: $store.settings.ipPreference) {
                    ForEach(IPFamilyPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("異常時自動交叉驗證", isOn: $store.settings.autoCrossValidation)
            } header: {
                Text("測試")
            } footer: {
                Text("自動時間：速度穩定後提前結束（6–15 秒）。自動連線數：依頻寬在 2 / 4 / 8 / 16 之間調整。IP 協定限制套用於延遲與遺失測試。")
            }
            Section("伺服器") {
                Picker("選擇方式", selection: $store.settings.serverSelection) {
                    ForEach(ServerSelectionMode.allCases) { Text($0.displayName).tag($0) }
                }
                if store.settings.serverSelection == .manual {
                    Picker("伺服器", selection: $store.settings.manualServerID) {
                        ForEach(store.allServers) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                NavigationLink("管理伺服器") { ServersView() }
            }
            Section("預設模式") {
                Picker("測速頁預設", selection: $store.settings.defaultTestMode) {
                    ForEach(DefaultTestMode.allCases) { Text($0.displayName).tag($0) }
                }
                if store.settings.defaultTestMode == .customProfile {
                    Picker("設定檔", selection: $store.settings.defaultProfileID) {
                        ForEach(store.settings.allProfiles) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Picker("診斷細節層級", selection: $store.settings.detailLevel) {
                    ForEach(DiagnosticDetailLevel.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section("外觀") {
                Picker("外觀", selection: $store.settings.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section {
                Picker("保留歷史", selection: $store.settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("匯出格式", selection: $store.settings.exportFormat) {
                    ForEach(ExportFormatSetting.allCases) { Text($0.displayName).tag($0) }
                }
                Button("刪除全部歷史與診斷紀錄", role: .destructive) { confirmDelete = true }
            } header: {
                Text("資料")
            } footer: {
                Text("所有歷史資料只以 SwiftData 儲存在這台裝置。")
            }
            Section {
                Toggle("儲存測試位置（僅本機）", isOn: $store.settings.storeLocation)
                    .onChange(of: store.settings.storeLocation) { _, on in if on { app.location.requestPermission() } }
                Toggle("匯出時包含位置", isOn: $store.settings.includeLocationInExports)
                    .disabled(!store.settings.storeLocation)
                Toggle("背景短暫檢查（iOS 排程）", isOn: $store.settings.backgroundChecks)
            } header: {
                Text("隱私與背景")
            } footer: {
                Text("位置預設關閉，只存在本機、不會傳送到任何伺服器。背景檢查由 iOS 決定執行時機（通常一天數次、每次約 30 秒內），無法做到持續每秒背景監控。")
            }
            Section("關於") {
                NavigationLink("平台限制說明") { LimitationsView() }
                LabeledContent("版本", value: ExportService.appVersion)
                Button("重設所有設定") { store.reset() }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("設定")
        .confirmationDialog("確定刪除？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除全部", role: .destructive) { try? app.history.deleteAll() }
        }
    }
}

struct ServersView: View {
    @Environment(SettingsStore.self) private var store
    @State private var name = ""
    @State private var location = ""
    @State private var url = "https://"
    @State private var udpPort = "9001"
    @State private var icmpHost = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("內建") {
                ForEach(ServerDescriptor.builtIn) { s in
                    VStack(alignment: .leading) {
                        Text(s.name)
                        Text(s.baseURL.absoluteString).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Section("自架 ChaiNet 伺服器") {
                ForEach(store.settings.customServers) { s in
                    VStack(alignment: .leading) {
                        Text(s.name)
                        Text("\(s.baseURL.absoluteString) · UDP \(s.udpEchoPort.map(String.init) ?? "—")").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .onDelete { store.settings.customServers.remove(atOffsets: $0) }
            }
            Section {
                TextField("名稱", text: $name)
                TextField("位置（例如 Taipei）", text: $location)
                TextField("URL", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("UDP echo port", text: $udpPort).keyboardType(.numberPad)
                TextField("ICMP 主機（可留空）", text: $icmpHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let error { Text(error).foregroundStyle(Theme.critical).font(.caption) }
                Button("加入") { add() }
            } header: {
                Text("新增伺服器")
            } footer: {
                Text("部署 repo 中的 backend/（Go）即可取得 /ping、/download、/upload、/health、/info 與 UDP echo。")
            }
        }
        .navigationTitle("伺服器")
    }

    private func add() {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), parsed.scheme?.hasPrefix("http") == true, parsed.host() != nil else {
            error = "URL 格式不正確"
            return
        }
        let server = ServerDescriptor(id: UUID().uuidString, name: name.isEmpty ? (parsed.host() ?? "Server") : name,
                                      location: location.isEmpty ? "自訂" : location, kind: .chainet, baseURL: parsed,
                                      udpEchoPort: UInt16(udpPort), icmpHost: icmpHost.isEmpty ? nil : icmpHost, isCustom: true)
        store.settings.customServers.append(server)
        name = ""; location = ""; url = "https://"; icmpHost = ""; error = nil
    }
}

struct LimitationsView: View {
    var body: some View {
        List {
            ForEach(DiagnosticReportGenerator.platformLimitations, id: \.self) { Text($0).font(.footnote) }
            Section("替代方式") {
                Text("行動網路訊號：在「電話」App 輸入 *3001#12345#*（Field Test Mode，部分機型 / 電信商可用）可查看 RSRP / SINR，再與 ChaiNet 的結果對照。").font(.footnote)
                Text("LTE / 5G 比較：在「設定 › 行動服務 › 語音與數據」切換後，把測試加入同一個診斷工作階段。").font(.footnote)
                Text("Wi-Fi 訊號：使用路由器管理介面或 Apple「AirPort 工具程式」的 Wi-Fi 掃描功能。").font(.footnote)
                Text("長時間監測：保持 ChaiNet 在前景並接上電源，或在自己的伺服器上執行監測。").font(.footnote)
            }
        }
        .navigationTitle("平台限制")
    }
}
