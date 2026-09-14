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
    @State private var appLockEnabled = AppSettings.appLockEnabled
    @State private var dailyReminderEnabled = AppSettings.dailyReminderEnabled
    @State private var overspendAlertEnabled = AppSettings.overspendAlertEnabled
    @State private var reminderTime = Date()
    @State private var notificationMessage: String?
    @State private var showingNotificationAlert = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    shortcutGrid
                    notificationCard
                    securityCard
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
            .alert("通知", isPresented: $showingNotificationAlert) {
                Button("好") {}
            } message: {
                Text(notificationMessage ?? "")
            }
            .alert("確定刪除所有紀錄？", isPresented: $showingDeleteAll) {
                Button("刪除", role: .destructive) { deleteAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此動作無法復原，建議先匯出 CSV 備份。")
            }
            .onAppear {
                appLockEnabled = AppSettings.appLockEnabled
                dailyReminderEnabled = AppSettings.dailyReminderEnabled
                overspendAlertEnabled = AppSettings.overspendAlertEnabled
                var components = DateComponents()
                components.hour = AppSettings.dailyReminderHour
                components.minute = AppSettings.dailyReminderMinute
                reminderTime = DateHelper.calendar.date(from: components) ?? Date()
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
            NavigationLink { BackupView() } label: {
                shortcut("備份還原", "arrow.up.arrow.down.circle.fill", Color(hex: "#32ADE6"))
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

    // MARK: - 通知

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "提醒", systemImage: "bell.badge")

            Toggle(isOn: $dailyReminderEnabled) {
                Text("每天提醒我記帳").font(.subheadline)
            }
            .onChange(of: dailyReminderEnabled) { _, newValue in
                AppSettings.dailyReminderEnabled = newValue
                if newValue { askNotificationPermission() } else { NotificationService.syncDailyReminder() }
            }

            if dailyReminderEnabled {
                DatePicker("提醒時間", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    .font(.subheadline)
                    .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                    .onChange(of: reminderTime) { _, newValue in
                        let components = DateHelper.calendar.dateComponents([.hour, .minute], from: newValue)
                        AppSettings.dailyReminderHour = components.hour ?? 21
                        AppSettings.dailyReminderMinute = components.minute ?? 0
                        NotificationService.syncDailyReminder()
                    }
            }

            Divider()

            Toggle(isOn: $overspendAlertEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("超速消費警告").font(.subheadline)
                    Text("燒錢速度轉紅燈時提醒一次").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .onChange(of: overspendAlertEnabled) { _, newValue in
                AppSettings.overspendAlertEnabled = newValue
                if newValue { askNotificationPermission() }
            }

            Text("通知全部由這台裝置自己排程，不經過任何伺服器。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func askNotificationPermission() {
        Task {
            let granted = await NotificationService.requestAuthorization()
            await MainActor.run {
                if granted {
                    NotificationService.syncDailyReminder()
                } else {
                    notificationMessage = "通知權限沒有開啟，請到 設定 → 通知 → MoneyLeft 開啟。"
                    showingNotificationAlert = true
                }
            }
        }
    }

    // MARK: - 安全

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "安全", systemImage: "lock.shield")
            Toggle(isOn: $appLockEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("開啟 App 需要驗證").font(.subheadline)
                    Text("Face ID / Touch ID / 裝置密碼").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(!AppLockController.biometryAvailable)
            .onChange(of: appLockEnabled) { _, newValue in
                AppSettings.appLockEnabled = newValue
            }
            if !AppLockController.biometryAvailable {
                Text("這台裝置沒有設定密碼或生物辨識，無法啟用。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .card()
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
            NavigationLink { BackupView() } label: {
                row("備份與還原", "externaldrive")
            }
            Button { export() } label: {
                row("匯出 CSV", "square.and.arrow.up")
            }
            NavigationLink { PhraseMappingView() } label: {
                row("語音個人詞庫", "text.book.closed")
            }
            NavigationLink { PrivacyView() } label: {
                row("隱私說明", "hand.raised.fill")
            }
            Button(role: .destructive) { showingDeleteAll = true } label: {
                row("刪除所有紀錄", "trash", tint: Color(hex: "#FF453A"))
            }
            Text("共 \(expenses.count) 筆紀錄，全部只存在這台裝置上。")
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
            Text("無廣告 · 無訂閱 · 零連網 · 不蒐集任何資料")
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
                item("沒有雲端、沒有同步", "App 不含任何連網能力，資料不會離開這台裝置。換手機請用「備份與還原」。")
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

/// 語音記帳學到的個人詞庫
struct PhraseMappingView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PhraseMapping.updatedAt, order: .reverse) private var mappings: [PhraseMapping]

    var body: some View {
        Form {
            if mappings.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("還沒有學到東西").font(.subheadline)
                        Text("用語音記帳時，如果 App 猜錯分類、你手動改掉，它就會把「這句話 → 這個分類」記起來，下次直接命中。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(mappings) { mapping in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mapping.phrase).font(.subheadline)
                                Text("→ \(mapping.categoryName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(mapping.hitCount) 次")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("已學會 \(mappings.count) 個說法")
                } footer: {
                    Text("覺得哪個學錯了就左滑刪掉。")
                }
            }
        }
        .navigationTitle("語音個人詞庫")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets where index < mappings.count {
            context.delete(mappings[index])
        }
        try? context.save()
    }
}
