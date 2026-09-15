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
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var weightText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                unitCard
                healthCard
                notificationCard
                strideCard
                bodyCard
                cueCard
                mapCard
                permissionCard
                dataCard
                aboutCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
        }
        .screenBackground()
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
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
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
