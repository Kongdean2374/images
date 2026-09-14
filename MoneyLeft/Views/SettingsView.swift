import SwiftUI
import SwiftData
import UIKit

/// 「更多」分頁：上面是快速入口九宮格，下面是各項設定。
struct MoreView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var liveActivity: LiveActivityController
    @Query private var expenses: [Expense]

    @State private var keepReceiptImage = AppSettings.keepReceiptImage
    @State private var autoCloseHours = AppSettings.liveActivityAutoCloseHours
    @State private var quickAmounts = AppSettings.quickAmounts
    @State private var exportFile: ExportFile?
    @State private var showingExportError = false
    @State private var showingDeleteAll = false
    @State private var showingReceiptFlow = false
    @State private var cloudEnabled = AppSettings.cloudSyncEnabled
    @State private var cloudMessage: String?
    @State private var showingCloudAlert = false
    @State private var isSwitchingCloud = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    shortcutGrid
                    cloudCard
                    liveActivityCard
                    receiptCard
                    dataCard
                    aboutCard
                    Color.clear.frame(height: 10)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $exportFile) { ActivityView(items: [$0.url]) }
            .sheet(isPresented: $showingReceiptFlow) { ReceiptFlowView() }
            .alert("匯出失敗", isPresented: $showingExportError) { Button("好") {} }
            .alert("iCloud 同步", isPresented: $showingCloudAlert) {
                Button("知道了") {}
            } message: {
                Text(cloudMessage ?? "")
            }
            .alert("確定刪除所有紀錄？", isPresented: $showingDeleteAll) {
                Button("刪除", role: .destructive) { deleteAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此動作無法復原，建議先匯出 CSV 備份。")
            }
            .onAppear {
                cloudEnabled = AppSettings.cloudSyncEnabled
            }
        }
    }

    // MARK: - 快速入口

    private var shortcutGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            NavigationLink { BudgetSettingsView() } label: {
                shortcut("預算設定", "target", Theme.accent)
            }
            NavigationLink { CategoryManagerView() } label: {
                shortcut("分類管理", "square.grid.2x2.fill", Color(hex: "#34C759"))
            }
            NavigationLink { EmotionTagManagerView() } label: {
                shortcut("情緒標籤", "heart.fill", Color(hex: "#FF375F"))
            }
            NavigationLink { QuickAmountEditor(amounts: $quickAmounts) } label: {
                shortcut("快速金額", "plusminus.circle.fill", Color(hex: "#FF9F0A"))
            }
            Button { showingReceiptFlow = true } label: {
                shortcut("收據辨識", "doc.text.viewfinder", Color(hex: "#BF5AF2"))
            }
            Button { export() } label: {
                shortcut("匯出 CSV", "square.and.arrow.up.fill", Color(hex: "#32ADE6"))
            }
        }
        .buttonStyle(.plain)
    }

    private func shortcut(_ title: String, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - iCloud

    private var cloudCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "iCloud 私人同步", systemImage: "icloud") {
                statusBadge
            }

            Toggle(isOn: Binding(
                get: { cloudEnabled },
                set: { switchCloud(to: $0) }
            )) {
                Text("開啟同步").font(.subheadline)
            }
            .disabled(isSwitchingCloud)

            if let note = AppSettings.cloudFailureNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("資料只會流動在你自己的 Apple 帳號裡，不經過任何開發者或第三方伺服器。切換後需完全關閉 App 再重開；若這份簽名沒有 iCloud 權限（免費 Apple ID 自簽就會這樣），App 會自動維持本機模式，**不會**閃退或遺失資料。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var statusBadge: some View {
        let text: String
        let color: Color
        switch Persistence.status {
        case .cloud: text = "已連上 iCloud"; color = Color(hex: "#34C759")
        case .local: text = "僅存在本機"; color = .secondary
        case .cloudUnavailable: text = "iCloud 不可用"; color = .orange
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private func switchCloud(to newValue: Bool) {
        guard !isSwitchingCloud else { return }
        isSwitchingCloud = true
        let result = newValue
            ? CloudSyncCoordinator.enable(currentContainer: AppContainer.shared)
            : CloudSyncCoordinator.disable(currentContainer: AppContainer.shared)
        cloudEnabled = AppSettings.cloudSyncEnabled
        cloudMessage = result.message
        showingCloudAlert = true
        isSwitchingCloud = false
    }

    // MARK: - 動態島

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "動態島記帳", systemImage: "capsule.portrait")

            Toggle(isOn: Binding(
                get: { liveActivity.isActive },
                set: { newValue in
                    if newValue { liveActivity.start(context: context) } else { liveActivity.end() }
                }
            )) {
                Text("目前記帳中").font(.subheadline)
            }

            Picker(selection: $autoCloseHours) {
                Text("不自動關閉").tag(0)
                ForEach([1, 2, 4, 8, 12, 24], id: \.self) { Text("\($0) 小時後").tag($0) }
            } label: {
                Text("自動關閉").font(.subheadline)
            }
            .onChange(of: autoCloseHours) { _, newValue in
                AppSettings.liveActivityAutoCloseHours = newValue
            }

            if let error = liveActivity.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .card()
    }

    // MARK: - 收據

    private var receiptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "收據辨識", systemImage: "doc.text.viewfinder")
            Toggle(isOn: $keepReceiptImage) {
                Text("保留收據原圖").font(.subheadline)
            }
            .onChange(of: keepReceiptImage) { _, newValue in
                AppSettings.keepReceiptImage = newValue
            }
            Text("關掉之後只會取數字與日期，不保存照片，資料庫會小很多。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: - 資料

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "資料", systemImage: "externaldrive")
            Button { export() } label: {
                row("匯出 CSV", "square.and.arrow.up")
            }
            NavigationLink { PrivacyView() } label: {
                row("隱私說明", "hand.raised.fill")
            }
            Button(role: .destructive) { showingDeleteAll = true } label: {
                row("刪除所有紀錄", "trash", tint: Color(hex: "#FF453A"))
            }
            Text("共 \(expenses.count) 筆紀錄。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
        .buttonStyle(.plain)
    }

    private func row(_ title: String, _ icon: String, tint: Color = .primary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(tint)
            Text(title).font(.subheadline).foregroundStyle(tint)
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var aboutCard: some View {
        VStack(spacing: 6) {
            Text("MoneyLeft \(appVersion)")
                .font(.caption.weight(.semibold))
            Text("無廣告 · 無訂閱 · 不蒐集任何資料")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
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
        for expense in expenses { context.delete(expense) }
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
                Text("記帳時可以一鍵加上這些金額，例如常喝的那杯咖啡。動態島也會用前三個。")
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
        context.insert(EmotionTag(name: trimmed, iconName: "tag.fill", colorHex: newColor, isBuiltIn: false, sortOrder: tags.count))
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
                item("你可以隨時帶走資料", "一鍵匯出 CSV，資料是你的。")
            }
            .padding()
        }
        .navigationTitle("隱私說明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func item(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "checkmark.shield.fill").font(.headline)
            Text(body).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
