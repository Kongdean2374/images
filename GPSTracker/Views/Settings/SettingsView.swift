import SwiftUI
import SwiftData
import CoreLocation
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @Query private var sessions: [WorkoutSession]
    @StateObject private var location = LocationManager.shared

    @State private var showDeleteAll = false
    @StateObject private var health = HealthKitManager.shared
    @State private var healthMessage: String?
    @State private var isSyncingAll = false
    @State private var notificationsAuthorized = false
    @State private var showOnboardingAgain = false
    @State private var showAnnounceEditor = false
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var weightText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                group("健康與資料") {
                    healthCard
                    strideCard
                }
                group("提醒") {
                    notificationCard
                }
                group("運動偏好") {
                    homeLayoutCard
                    unitCard
                    bodyCard
                    announcementCard
                    powerCard
                    cueCard
                    mapCard
                }
                group("系統") {
                    permissionCard
                    dataCard
                }
                group("說明與條款") {
                    documentsCard
                    aboutCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
        }
        .screenBackground()
        .sheet(isPresented: $showAnnounceEditor) {
            AnnounceIntervalEditorSheet(unit: settings.unit,
                                        initialRaw: settings.announceIntervalRaw) { value in
                settings.announceIntervalRaw = value
            }
        }
        .navigationTitle("設定")
        .onAppear {
            weightText = String(format: "%.0f", settings.bodyWeight)
            health.refreshAvailability()
        }
        .task {
            notificationsAuthorized = await NotificationManager.authorizationStatus() == .authorized
        }
        .alert("刪除所有資料？", isPresented: $showDeleteAll) {
            Button("取消", role: .cancel) {}
            Button("全部刪除", role: .destructive) { deleteAll() }
        } message: {
            Text("此操作無法復原，共 \(sessions.count) 筆紀錄。")
        }
        .sheet(isPresented: $showExport) {
            if let exportURL {
                VStack(spacing: 16) {
                    Text("已產生 CSV")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    ShareLink(item: exportURL) {
                        Label("分享／儲存", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding()
                .presentationDetents([.height(200)])
            }
        }
    }


    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.9)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 健康 App

    private var healthCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("健康 App", systemImage: "heart.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(health.availability.displayName)
                        .font(.caption)
                        .foregroundStyle(health.isReady ? Theme.mint : Theme.amber)
                }

                Toggle("運動結束自動寫入健康 App", isOn: Binding(
                    get: { settings.healthKitEnabled },
                    set: { newValue in
                        settings.healthKitEnabled = newValue
                        if newValue {
                            Task {
                                let ok = await health.requestAuthorization()
                                if !ok {
                                    await MainActor.run {
                                        settings.healthKitEnabled = false
                                        healthMessage = health.availability == .notEntitled
                                            ? "此安裝版本沒有健康權限。免費 Apple ID 自簽無法啟用 HealthKit，可改用 GPX／TCX 匯出。"
                                            : "尚未取得健康 App 權限。"
                                    }
                                }
                            }
                        }
                    }))
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)

                Toggle("讀取已有的心率資料（選配）", isOn: Binding(
                    get: { settings.readHeartRate },
                    set: { settings.readHeartRate = $0 }))
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)
                .disabled(!health.isReady)

                Text("只寫入體能訓練、距離、熱量與 GPS 路線，不寫入步數（避免與 iPhone 自動計步重複累加）。心率僅被動讀取其他來源已存在的資料，不連接任何裝置。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                if let healthMessage {
                    Text(healthMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                }

                NavigationLink {
                    HealthImportView()
                } label: {
                    Label("一鍵匯入健康 App 的歷史紀錄", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)

                Button {
                    Task { await syncAll() }
                } label: {
                    if isSyncingAll {
                        ProgressView()
                    } else {
                        Label("補傳未同步的紀錄", systemImage: "arrow.up.heart")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!health.isReady || isSyncingAll)

                Button {
                    Task {
                        if let mass = await health.latestBodyMass() {
                            await MainActor.run {
                                settings.bodyWeight = mass
                                weightText = String(format: "%.0f", mass)
                            }
                        }
                    }
                } label: {
                    Label("從健康 App 讀取體重", systemImage: "scalemass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!health.isReady)
            }
        }
    }

    @MainActor
    private func syncAll() async {
        isSyncingAll = true
        defer { isSyncingAll = false }
        let count = await HealthKitSync.syncPending(sessions)
        try? context.save()
        healthMessage = count > 0 ? "已補傳 \(count) 筆紀錄" : "沒有需要補傳的紀錄"
    }

    // MARK: 通知

    private var notificationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("提醒", systemImage: "bell.badge")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(notificationsAuthorized ? "已允許" : "未允許")
                        .font(.caption)
                        .foregroundStyle(notificationsAuthorized ? Theme.mint : Theme.amber)
                }

                Toggle("每日步數提醒", isOn: Binding(
                    get: { settings.stepReminderEnabled },
                    set: { newValue in
                        settings.stepReminderEnabled = newValue
                        Task { await applyNotificationSettings(request: newValue) }
                    }))
                .tint(Theme.accent)

                if settings.stepReminderEnabled {
                    HStack {
                        Text("提醒時間")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Picker("", selection: Binding(get: { settings.stepReminderHour },
                                                      set: { settings.stepReminderHour = $0 })) {
                            ForEach(6...23, id: \.self) { Text("\($0):00").tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accent)
                    }
                }

                Toggle("連續天數即將中斷提醒", isOn: Binding(
                    get: { settings.streakReminderEnabled },
                    set: { newValue in
                        settings.streakReminderEnabled = newValue
                        Task { await applyNotificationSettings(request: newValue) }
                    }))
                .tint(Theme.accent)

                HStack {
                    Text("久坐提醒")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("", selection: Binding(get: { settings.sedentaryReminderHours },
                                                  set: { newValue in
                                                      settings.sedentaryReminderHours = newValue
                                                      Task { await applyNotificationSettings(request: newValue > 0) }
                                                  })) {
                        Text("關閉").tag(0)
                        Text("每 1 小時").tag(1)
                        Text("每 2 小時").tag(2)
                        Text("每 3 小時").tag(3)
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accent)
                }

                Text("全部由裝置本機排程，不需要網路或伺服器。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
        }
    }

    @MainActor
    private func applyNotificationSettings(request: Bool) async {
        if request {
            let granted = await NotificationManager.requestAuthorization()
            notificationsAuthorized = granted
            if !granted { return }
        }
        if settings.stepReminderEnabled {
            NotificationManager.scheduleDailyStepReminder(hour: settings.stepReminderHour,
                                                          goal: settings.dailyStepGoal)
        } else {
            NotificationManager.cancel(NotificationManager.Identifier.dailySteps)
        }
        if settings.streakReminderEnabled {
            let records = StatsEngine.personalRecords(sessions: sessions)
            NotificationManager.scheduleStreakReminder(streak: max(1, records.currentStreak))
        } else {
            NotificationManager.cancel(NotificationManager.Identifier.streak)
        }
        NotificationManager.scheduleSedentaryReminder(intervalHours: settings.sedentaryReminderHours)
    }

    // MARK: 步幅

    private var strideCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("個人步幅校正", systemImage: "ruler")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("每次 GPS 運動結束會用「實際距離 ÷ 步數」更新你的步幅，沒有訊號時就用它換算距離。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                strideRow(.walking, title: "走路步幅")
                strideRow(.running, title: "跑步步幅")

                NavigationLink {
                    StrideCalibrationView()
                } label: {
                    Label("開啟校正中心（自動計算精準度）", systemImage: "wand.and.stars")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func strideRow(_ profile: StrideProfile, title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f 公尺/步", StrideCalibration.stride(profile)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text(StrideCalibration.isCalibrated(profile)
                     ? String(format: "精準度 %.0f%%・樣本 %d",
                              StrideCalibration.confidence(profile) * 100,
                              StrideCalibration.sampleCount(profile))
                     : "尚未校正（使用平均值）")
                    .font(.caption2)
                    .foregroundStyle(StrideCalibration.isCalibrated(profile) ? Theme.mint : Theme.amber)
            }
        }
    }

    private var unitCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("單位")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Picker("單位", selection: Binding(get: { settings.unit },
                                                 set: { settings.unit = $0 })) {
                    ForEach(DistanceUnit.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var bodyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("個人資料")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Text("體重（公斤）")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TextField("65", text: $weightText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
                        .onChange(of: weightText) { _, newValue in
                            if let value = Double(newValue), value > 20, value < 250 {
                                settings.bodyWeight = value
                            }
                        }
                }
                Text("用於估算消耗熱量（MET 公式），不會離開此裝置。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                HStack {
                    Text("預設單圈距離")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(settings.lapDistance)) m")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Slider(value: Binding(get: { settings.lapDistance },
                                      set: { settings.lapDistance = $0 }),
                       in: 50...2000, step: 50)
                    .tint(Theme.accent)
            }
        }
    }

    private var homeLayoutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("首頁模式", systemImage: "square.grid.2x2")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("在首頁長按任一模式即可釘選到最上面，或從首頁隱藏。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if !settings.pinnedModes.isEmpty {
                    Text("已釘選")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    modeChips(settings.pinnedModes, tint: Theme.accent) { type in
                        settings.togglePinned(type)
                    }
                }

                if !settings.hiddenModes.isEmpty {
                    Text("已隱藏（點一下可恢復）")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    modeChips(settings.hiddenModes, tint: Theme.amber) { type in
                        settings.toggleHidden(type)
                    }
                }

                if settings.pinnedModes.isEmpty && settings.hiddenModes.isEmpty {
                    Text("目前顯示全部模式。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func modeChips(_ raws: [String], tint: Color, action: @escaping (WorkoutType) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(raws, id: \.self) { raw in
                    if let type = WorkoutType(rawValue: raw) {
                        Button {
                            action(type)
                            CueService.shared.impact(.soft)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: type.systemImage)
                                Text(type.shortName)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(tint.opacity(0.22)))
                            .foregroundStyle(tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var announcementCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("語音播報", systemImage: "speaker.wave.2.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(settings.announceIntervalText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(announceOptions, id: \.1) { label, value in
                            Button {
                                settings.announceIntervalRaw = value
                                CueService.shared.impact(.soft)
                            } label: {
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(settings.announceIntervalRaw == value
                                                               ? Theme.accent.opacity(0.3)
                                                               : Color.white.opacity(0.07)))
                                    .foregroundStyle(settings.announceIntervalRaw == value
                                                     ? Theme.accent : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            showAnnounceEditor = true
                            CueService.shared.impact(.soft)
                        } label: {
                            Label("自訂", systemImage: "slider.horizontal.3")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Theme.violet.opacity(0.25)))
                                .foregroundStyle(Theme.violet)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if settings.announceIntervalRaw != 0 {
                    Text("播報內容")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Toggle("距離", isOn: Binding(get: { settings.announceDistance },
                                               set: { settings.announceDistance = $0 }))
                    Toggle("平均配速", isOn: Binding(get: { settings.announcePace },
                                                 set: { settings.announcePace = $0 }))
                    Toggle("累計時間", isOn: Binding(get: { settings.announceDuration },
                                                 set: { settings.announceDuration = $0 }))
                    Toggle("與虛擬配速員的差距", isOn: Binding(get: { settings.announcePacerDelta },
                                                      set: { settings.announcePacerDelta = $0 }))
                }
            }
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
            .font(.subheadline)
        }
    }

    private var announceOptions: [(String, Double)] {
        [("關閉", 0), ("每 0.5 km", 500), ("每 1 km", 1000), ("每 2 km", 2000),
         ("每 5 分", -5), ("每 10 分", -10)]
    }

    private var powerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("電量與螢幕", systemImage: "battery.100percent.bolt")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Toggle("運動中保持螢幕開啟", isOn: Binding(get: { settings.keepScreenAwake },
                                                 set: { settings.keepScreenAwake = $0 }))
                Toggle("GPS 智慧省電", isOn: Binding(get: { settings.batterySaver },
                                                set: { settings.batterySaver = $0 }))
                Text("智慧省電會依你的速度調整定位取樣密度，並在系統低耗電模式下再降一級。長距離記錄可省下可觀電力，精度影響很小。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    Text("目前模式")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(location.powerModeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.mint)
                }
            }
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
            .font(.subheadline)
        }
    }

    private var cueCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("提示")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Toggle("語音播報", isOn: Binding(get: { settings.voiceCues },
                                              set: { settings.voiceCues = $0 }))
                Toggle("震動回饋", isOn: Binding(get: { settings.hapticCues },
                                              set: { settings.hapticCues = $0 }))
                Toggle("GPS 自動暫停", isOn: Binding(get: { settings.autoPause },
                                                 set: { settings.autoPause = $0 }))
                Toggle("靈動島／鎖定畫面即時活動", isOn: Binding(get: { settings.liveActivityEnabled },
                                                     set: { settings.liveActivityEnabled = $0 }))
            }
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private var mapCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("地圖")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Text("3D 傾斜角")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(settings.mapPitch))°")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Slider(value: Binding(get: { settings.mapPitch },
                                      set: { settings.mapPitch = $0 }),
                       in: 0...75, step: 5)
                    .tint(Theme.accent)
                Toggle("深色模式優先", isOn: Binding(get: { settings.preferDarkMode },
                                                set: { settings.preferDarkMode = $0 }))
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("權限狀態")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Image(systemName: location.isAuthorized ? "location.fill" : "location.slash.fill")
                        .foregroundStyle(location.isAuthorized ? Theme.mint : Theme.amber)
                    Text(permissionText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("系統設定") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                }
                Text("即使完全關閉定位，計圈、間歇、原地運動與手動輸入仍可正常使用。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var permissionText: String {
        switch location.authorizationStatus {
        case .authorizedAlways: return "定位：永遠允許（可背景記錄）"
        case .authorizedWhenInUse: return "定位：使用 App 時允許"
        case .denied: return "定位：已拒絕"
        case .restricted: return "定位：受限制"
        case .notDetermined: return "定位：尚未詢問"
        @unknown default: return "定位：未知狀態"
        }
    }

    private var dataCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("資料")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Text("已儲存紀錄")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(sessions.count) 筆")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                NavigationLink {
                    BackupView()
                } label: {
                    Label("備份與還原", systemImage: "externaldrive.badge.timemachine")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)

                Button {
                    exportURL = DataExporter.csv(sessions: sessions)
                    showExport = exportURL != nil
                } label: {
                    Label("匯出全部資料 CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    showDeleteAll = true
                } label: {
                    Label("刪除所有資料", systemImage: "trash")
                }
                .buttonStyle(SecondaryButtonStyle())
                .foregroundStyle(Theme.accentWarm)
            }
        }
    }

    private var documentsCard: some View {
        GlassCard(padding: 6) {
            VStack(spacing: 0) {
                documentRow(icon: "book.fill", title: "使用說明",
                            subtitle: "各種模式與資料流的圖解", tint: Theme.accent) {
                    UserGuideView()
                }
                rowDivider
                Button {
                    LiveActivityController.shared.endAll()
                    CueService.shared.impact(.medium)
                } label: {
                    documentRowContent(icon: "bolt.slash.circle.fill",
                                       title: "清除卡住的靈動島",
                                       subtitle: "運動已結束但靈動島還在時按這裡",
                                       tint: Theme.amber)
                }
                rowDivider
                documentRow(icon: "character.book.closed.fill", title: "名詞解釋",
                            subtitle: "CTL、ATL、TSB、ACWR⋯⋯白話版", tint: Theme.violet) {
                    GlossaryListView()
                }
                rowDivider
                documentRow(icon: "hand.raised.fill", title: "隱私政策",
                            subtitle: "中文 / English・含權限一覽", tint: Theme.mint) {
                    LegalView(document: .privacy)
                }
                rowDivider
                documentRow(icon: "doc.text.fill", title: "使用條款",
                            subtitle: "中文 / English", tint: Theme.amber) {
                    LegalView(document: .terms)
                }
                rowDivider
                Button {
                    settings.hasSeenOnboarding = false
                    showOnboardingAgain = true
                } label: {
                    documentRowContent(icon: "sparkles", title: "重新觀看導覽",
                                       subtitle: "再看一次開場說明", tint: Theme.violet)
                }
                .buttonStyle(.plain)
            }
        }
        .fullScreenCover(isPresented: $showOnboardingAgain) {
            NavigationStack { OnboardingView() }
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.07))
            .padding(.leading, 60)
    }

    private func documentRow<Destination: View>(icon: String,
                                                title: String,
                                                subtitle: String,
                                                tint: Color,
                                                @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            documentRowContent(icon: icon, title: title, subtitle: subtitle, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func documentRowContent(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("關於")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("GPS 路跑／健行軌跡記錄器")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text("全程本地端運算與儲存，不連後端伺服器，不需要帳號。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    Text("App 版本")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack {
                    Text("條款版本")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(LegalContent.version)（\(LegalContent.effectiveDate)）")
                        .font(.caption2)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private func deleteAll() {
        for session in sessions {
            context.delete(session)
        }
        try? context.save()
        CueService.shared.notify(.warning)
    }
}
