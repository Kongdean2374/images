import SwiftUI
import SwiftData

/// 一鍵匯入：把健康 App 裡的歷史運動（含其他 App 寫入的）變成本 App 的一般紀錄。
private struct ImportSourceRow: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
}

struct HealthImportView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var health = HealthKitManager.shared
    @StateObject private var importer = HealthKitImporter.shared

    @State private var range: ImportRange = .year3
    @State private var includeRoutes = true
    @State private var previewTotal: Int?
    @State private var previewNew: Int?
    @State private var isPreviewing = false
    @State private var message: String?

    private var importedCount: Int { sessions.filter { $0.isImported }.count }
    private var localCount: Int { sessions.filter { !$0.isImported }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                rangeCard
                actionCard
                if let result = importer.lastResult, !result.isEmpty { resultCard(result) }
                autoCard
                explainCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("匯入健康資料")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { health.refreshAvailability() }
    }

    // MARK: 區塊

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("健康 App", systemImage: "heart.text.square")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(health.availability.displayName)
                        .font(.caption)
                        .foregroundStyle(health.isReady ? Theme.mint : Theme.amber)
                }
                HStack {
                    StatPill(title: "App 內紀錄", value: "\(localCount)", tint: Theme.accent)
                    StatPill(title: "已匯入", value: "\(importedCount)", tint: Theme.mint)
                    StatPill(title: "合計", value: "\(sessions.count)", tint: Theme.amber)
                }
                if let date = settings.lastHealthImportDate {
                    Text("上次匯入：\(Fmt.dateTime(date))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !health.isReady {
                    Button {
                        Task {
                            let granted = await health.requestAuthorization()
                            if granted { settings.healthKitEnabled = true }
                            message = granted ? "已取得健康權限" : health.availability.displayName
                        }
                    } label: {
                        Label("授權健康 App", systemImage: "heart.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private var rangeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("匯入範圍")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Picker("範圍", selection: $range) {
                    ForEach(ImportRange.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("一併匯入 GPS 軌跡", isOn: $includeRoutes)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.textPrimary)
                Text("軌跡資料量較大，匯入會慢一些，但地圖、分段配速與海拔圖都能重現。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                Button {
                    Task { await runPreview() }
                } label: {
                    if isPreviewing {
                        ProgressView()
                    } else {
                        Label("先看看有幾筆", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!health.isReady || isPreviewing)

                if let previewTotal, let previewNew {
                    HStack {
                        Text("這個範圍共 \(previewTotal) 筆")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("可新增 \(previewNew) 筆")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(previewNew > 0 ? Theme.mint : Theme.textSecondary)
                    }
                }
            }
        }
    }

    private var actionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                if importer.isImporting {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: importer.progress)
                            .tint(Theme.accent)
                        HStack {
                            Text(importer.statusText)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button("中斷") { importer.cancel() }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accentWarm)
                        }
                        Text("每 25 筆就會存檔一次，中斷後已匯入的都會保留，再按一次匯入就會從沒處理到的繼續。")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Button {
                    Task { await runImport() }
                } label: {
                    Label("一鍵匯入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!health.isReady || importer.isImporting)

                Button {
                    Task { await runImportNew() }
                } label: {
                    Label("只抓最新的（快速刷新）", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!health.isReady || importer.isImporting)

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.mint)
                }
            }
        }
    }

    private func resultCard(_ result: ImportResult) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("上次匯入結果")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(result.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.mint)
                if let oldest = result.oldest, let newest = result.newest {
                    Text("涵蓋 \(Fmt.date(oldest)) ～ \(Fmt.date(newest))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !result.sources.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    Text("來源 App")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(sourceRows(result)) { row in
                        HStack {
                            Text(row.name)
                                .font(.caption)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(row.count) 筆")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var autoCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("自動更新")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                Toggle("每次開啟 App 自動抓新資料", isOn: Binding(
                    get: { settings.autoImportHealth },
                    set: { settings.autoImportHealth = $0 }))
                .tint(Theme.accent)

                Toggle("背景更新與達標通知", isOn: Binding(
                    get: { settings.backgroundUpdates },
                    set: { newValue in
                        settings.backgroundUpdates = newValue
                        Task {
                            if newValue {
                                _ = await NotificationManager.requestAuthorization()
                                HealthBackgroundMonitor.shared.start()
                            } else {
                                HealthBackgroundMonitor.shared.stop()
                            }
                        }
                    }))
                .tint(Theme.accent)

                HStack {
                    Text("每日距離目標")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(String(format: "%.1f 公里", settings.dailyDistanceGoal))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: Binding(get: { settings.dailyDistanceGoal },
                                      set: { settings.dailyDistanceGoal = $0 }),
                       in: 1...30, step: 0.5)
                    .tint(Theme.accent)

                Text("開啟背景更新後，就算 App 沒有在前景，健康 App 有新資料時系統也會喚醒它：達到步數或距離目標會直接推播，其他運動 App 新增的訓練也會自動匯入。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private var explainCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("資料怎麼流動", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("・在這個 App 記錄的運動 → 寫入健康 App，其他 App 也讀得到")
                Text("・其他 App（Nike、Strava、Apple Watch…）寫入健康的運動 → 匯入成本 App 的一般紀錄")
                Text("・匯入的紀錄會標記來源與健康 App 的識別碼，不會重複匯入，也不會再寫回去造成重複")
                Text("・匯入後所有統計、圖表、個人紀錄、步幅校正都會把它們一起算進去")
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private func sourceRows(_ result: ImportResult) -> [ImportSourceRow] {
        result.sources
            .map { ImportSourceRow(name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: 動作

    private func runPreview() async {
        isPreviewing = true
        defer { isPreviewing = false }
        let result = await importer.preview(range: range, existing: sessions)
        previewTotal = result.total
        previewNew = result.new
    }

    private func runImport() async {
        message = nil
        let result = await importer.importWorkouts(range: range,
                                                   context: context,
                                                   existing: sessions,
                                                   includeRoutes: includeRoutes)
        message = result.summary
        previewTotal = nil
        previewNew = nil
        if result.imported > 0 { CueService.shared.notify(.success) }
    }

    private func runImportNew() async {
        message = nil
        let result = await importer.importNew(context: context, existing: sessions)
        message = result.imported > 0 ? result.summary : "沒有新的紀錄"
        if result.imported > 0 { CueService.shared.notify(.success) }
    }
}
