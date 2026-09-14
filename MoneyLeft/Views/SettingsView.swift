import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var liveActivity: LiveActivityController
    @Query private var expenses: [Expense]

    @State private var cloudSyncEnabled = AppSettings.cloudSyncEnabled
    @State private var keepReceiptImage = AppSettings.keepReceiptImage
    @State private var autoCloseHours = AppSettings.liveActivityAutoCloseHours
    @State private var quickAmounts = AppSettings.quickAmounts
    @State private var exportFile: ExportFile?
    @State private var showingExportError = false
    @State private var showingDeleteAll = false
    @State private var showingCloudNote = false

    var body: some View {
        NavigationStack {
            Form {
                Section("記帳") {
                    NavigationLink { BudgetSettingsView() } label: {
                        Label("預算設定", systemImage: "target")
                    }
                    NavigationLink { CategoryManagerView() } label: {
                        Label("分類管理", systemImage: "square.grid.2x2")
                    }
                    NavigationLink { EmotionTagManagerView() } label: {
                        Label("情緒標籤", systemImage: "heart.text.square")
                    }
                    NavigationLink { QuickAmountEditor(amounts: $quickAmounts) } label: {
                        Label("快速金額按鈕", systemImage: "plusminus.circle")
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { liveActivity.isActive },
                        set: { newValue in
                            if newValue { liveActivity.start(context: context) } else { liveActivity.end() }
                        }
                    )) {
                        Label("動態島記帳中", systemImage: "capsule.portrait")
                    }
                    Picker(selection: $autoCloseHours) {
                        Text("不自動關閉").tag(0)
                        ForEach([1, 2, 4, 8, 12, 24], id: \.self) { hour in
                            Text("\(hour) 小時後").tag(hour)
                        }
                    } label: {
                        Label("自動關閉", systemImage: "timer")
                    }
                    .onChange(of: autoCloseHours) { _, newValue in
                        AppSettings.liveActivityAutoCloseHours = newValue
                    }
                    if let error = liveActivity.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("動態島")
                } footer: {
                    Text("在動態島上可以直接加金額、切分類、按一下就記帳，不用進 App。")
                }

                Section {
                    Toggle(isOn: $keepReceiptImage) {
                        Label("保留收據原圖", systemImage: "photo.stack")
                    }
                    .onChange(of: keepReceiptImage) { _, newValue in
                        AppSettings.keepReceiptImage = newValue
                    }
                } header: {
                    Text("收據辨識")
                } footer: {
                    Text("關掉之後 OCR 只會取數字與日期，不保存照片，資料庫會小很多。")
                }

                Section {
                    Toggle(isOn: $cloudSyncEnabled) {
                        Label("iCloud 私人同步", systemImage: "icloud")
                    }
                    .onChange(of: cloudSyncEnabled) { _, newValue in
                        AppSettings.cloudSyncEnabled = newValue
                        showingCloudNote = true
                    }
                    HStack {
                        Label("目前狀態", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(Persistence.isUsingCloudKit ? "已連上 iCloud" : "僅存在本機")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("同步（可選）")
                } footer: {
                    Text("資料只會流動在你自己的 Apple 帳號裡，不會經過任何開發者或第三方伺服器。切換後需要重新開啟 App 才會生效；若憑證沒有 iCloud 權限，會自動維持本機模式。")
                }

                Section {
                    Button {
                        export()
                    } label: {
                        Label("匯出 CSV", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink { PrivacyView() } label: {
                        Label("隱私說明", systemImage: "hand.raised.fill")
                    }
                } header: {
                    Text("資料")
                } footer: {
                    Text("共 \(expenses.count) 筆紀錄，全部存在這台裝置上。")
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteAll = true
                    } label: {
                        Label("刪除所有紀錄", systemImage: "trash")
                    }
                } footer: {
                    Text("MoneyLeft \(appVersion)｜無廣告、無訂閱、不蒐集任何資料")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $exportFile) { file in
                ActivityView(items: [file.url])
            }
            .alert("匯出失敗", isPresented: $showingExportError) {
                Button("好") {}
            }
            .alert("切換同步模式", isPresented: $showingCloudNote) {
                Button("知道了") {}
            } message: {
                Text("請完全關閉 App 再重新開啟，資料容器才會切換。")
            }
            .alert("確定刪除所有紀錄？", isPresented: $showingDeleteAll) {
                Button("刪除", role: .destructive) { deleteAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此動作無法復原。建議先匯出 CSV 備份。")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    private func export() {
        do {
            let all = CSVExporter.allExpenses(in: context)
            exportFile = ExportFile(url: try CSVExporter.writeFile(expenses: all))
        } catch {
            showingExportError = true
        }
    }

    private func deleteAll() {
        for expense in expenses {
            context.delete(expense)
        }
        try? context.save()
        BudgetService.refreshWidgetSnapshot(context: context)
    }
}

/// 分享面板用的包裝（避免對系統型別加 Identifiable）
struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 系統分享面板
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 快速金額按鈕編輯
struct QuickAmountEditor: View {
    @Binding var amounts: [Int]
    @State private var newAmount: String = ""

    var body: some View {
        Form {
            Section {
                ForEach(amounts, id: \.self) { amount in
                    Text("+\(amount)").monospacedDigit()
                }
                .onDelete { offsets in
                    amounts.remove(atOffsets: offsets)
                    AppSettings.quickAmounts = amounts
                }
            } header: {
                Text("目前的按鈕")
            } footer: {
                Text("記帳時可以一鍵加上這些金額，例如常喝的那杯咖啡。")
            }

            Section("新增") {
                HStack {
                    TextField("金額", text: $newAmount)
                        .keyboardType(.numberPad)
                    Button("加入") {
                        if let value = Int(newAmount), value > 0, !amounts.contains(value) {
                            amounts.append(value)
                            amounts.sort()
                            AppSettings.quickAmounts = amounts
                        }
                        newAmount = ""
                    }
                    .disabled(Int(newAmount) == nil)
                }
            }
        }
        .navigationTitle("快速金額")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 情緒標籤管理（內建三個 + 自訂）
struct EmotionTagManagerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \EmotionTag.sortOrder) private var tags: [EmotionTag]

    @State private var newName: String = ""
    @State private var newColor: String = "#0A84FF"

    var body: some View {
        Form {
            Section("標籤") {
                ForEach(tags) { tag in
                    HStack(spacing: 12) {
                        Image(systemName: tag.iconName)
                            .foregroundStyle(Color(hex: tag.colorHex))
                            .frame(width: 26)
                        Text(tag.name)
                        Spacer()
                        if tag.isBuiltIn {
                            Text("內建").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: delete)
            }

            Section("新增自訂標籤") {
                TextField("名稱（例如：投資、送禮）", text: $newName)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                    ForEach(Color.palette, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(height: 30)
                            .overlay {
                                if hex == newColor {
                                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                }
                            }
                            .onTapGesture { newColor = hex }
                    }
                }
                .padding(.vertical, 4)
                Button("新增標籤") { add() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("情緒標籤")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func add() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let tag = EmotionTag(name: trimmed, iconName: "tag.fill", colorHex: newColor, isBuiltIn: false, sortOrder: tags.count)
        context.insert(tag)
        try? context.save()
        newName = ""
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets where index < tags.count {
            context.delete(tags[index])
        }
        try? context.save()
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                item("資料只存在這台裝置", "所有記帳紀錄、收據照片都寫在 App 自己的資料庫裡，不會上傳到任何伺服器。")
                item("不需要帳號", "沒有註冊、沒有登入、沒有任何身分識別。")
                item("收據辨識在本機完成", "使用 Apple 的 Vision 框架做文字辨識，照片不會離開裝置。")
                item("iCloud 同步是可選的", "開啟後資料會同步到「你自己的」iCloud 私有資料庫，開發者看不到，也沒有任何第三方經手。")
                item("沒有廣告、沒有追蹤", "App 內沒有任何廣告 SDK、分析 SDK 或第三方函式庫。")
                item("你可以隨時帶走資料", "設定頁一鍵匯出 CSV，資料是你的。")
            }
            .padding()
        }
        .navigationTitle("隱私說明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func item(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "checkmark.shield.fill")
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
