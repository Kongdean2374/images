import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 備份與還原：所有紀錄、設定、校正值與課表匯出成一個檔案。
struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var goals: [WorkoutGoal]
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var manager = BackupManager.shared

    @State private var includeRoutes = true
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var showImporter = false
    @State private var pendingPayload: BackupPayload?
    @State private var restoreMode: RestoreMode = .merge
    @State private var restoreSettings = true
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var showRestoreConfirm = false

    private var routePointCount: Int {
        sessions.reduce(0) { $0 + $1.routePoints.count }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                exportCard
                restoreCard
                if let payload = pendingPayload { previewCard(payload) }
                warningCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("備份與還原")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let exportURL {
                VStack(spacing: 16) {
                    Text(exportURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text("把檔案存到「檔案」App、iCloud 雲碟或傳給自己，換手機時就能還原。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    ShareLink(item: exportURL) {
                        Label("儲存備份檔", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding()
                .presentationDetents([.height(240)])
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert("確定要還原？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button(restoreMode == .replace ? "清空並還原" : "合併還原",
                   role: restoreMode == .replace ? .destructive : nil) {
                performRestore()
            }
        } message: {
            Text(restoreMode == .replace
                 ? "會先刪除目前 \(sessions.count) 筆紀錄，再還原備份內容。此動作無法復原。"
                 : "只會加入備份中沒有的紀錄，現有資料不受影響。")
        }
    }

    // MARK: 區塊

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("目前資料", systemImage: "internaldrive")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    StatPill(title: "紀錄", value: "\(sessions.count)", tint: Theme.accent)
                    StatPill(title: "軌跡點", value: "\(routePointCount)", tint: Theme.mint)
                    StatPill(title: "目標", value: "\(goals.count)", tint: Theme.amber)
                }
                if DatabaseHealth.needsAttention {
                    Label(DatabaseHealth.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accentWarm)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var exportCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("建立備份", systemImage: "arrow.down.doc")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("包含所有運動紀錄、分圈、目標、個人設定、步幅校正、自訂動作、課表與體測標準。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                Toggle("包含 GPS 軌跡點", isOn: $includeRoutes)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.textPrimary)
                Text(includeRoutes
                     ? "檔案較大（約 \(estimatedSizeText)），但地圖與分段配速都能完整還原。"
                     : "檔案很小，但還原後不會有地圖軌跡。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                if manager.isWorking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(manager.statusText)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Button {
                    exportURL = manager.exportBackup(sessions: sessions,
                                                     goals: goals,
                                                     includeRoutes: includeRoutes)
                    showShare = exportURL != nil
                    if exportURL == nil { errorMessage = "備份建立失敗" }
                } label: {
                    Label("匯出備份檔", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(manager.isWorking || sessions.isEmpty)
            }
        }
    }

    private var estimatedSizeText: String {
        let bytes = Double(routePointCount) * 120 + Double(sessions.count) * 400
        if bytes > 1_000_000 {
            return String(format: "%.1f MB", bytes / 1_000_000)
        }
        return String(format: "%.0f KB", bytes / 1000)
    }

    private var restoreCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("從備份還原", systemImage: "arrow.up.doc")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("選擇先前匯出的 .json 備份檔。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                Button {
                    showImporter = true
                } label: {
                    Label("選擇備份檔", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.mint)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.accentWarm)
                }
            }
        }
    }

    private func previewCard(_ payload: BackupPayload) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("備份內容", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                HStack {
                    StatPill(title: "紀錄", value: "\(payload.sessions.count)", tint: Theme.accent)
                    StatPill(title: "軌跡點", value: "\(payload.routePointCount)", tint: Theme.mint)
                    StatPill(title: "目標", value: "\(payload.goals.count)", tint: Theme.amber)
                }

                VStack(alignment: .leading, spacing: 4) {
                    detailRow("建立時間", Fmt.dateTime(payload.exportedAt))
                    detailRow("App 版本", payload.appVersion)
                    if let range = payload.dateRange {
                        detailRow("資料範圍", "\(Fmt.date(range.first)) ～ \(Fmt.date(range.last))")
                    }
                    detailRow("含軌跡", payload.includesRoutes ? "是" : "否")
                }

                Picker("方式", selection: $restoreMode) {
                    ForEach(RestoreMode.allCases) { mode in
                        Text(mode == .merge ? "合併" : "取代").tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(restoreMode.detail)
                    .font(.caption2)
                    .foregroundStyle(restoreMode == .replace ? Theme.amber : Theme.textSecondary)

                Toggle("一併還原設定與校正值", isOn: $restoreSettings)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.textPrimary)
                    .font(.subheadline)

                if manager.isWorking {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: manager.progress)
                            .tint(Theme.accent)
                        Text(manager.statusText)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                HStack(spacing: 12) {
                    Button("取消") {
                        pendingPayload = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        showRestoreConfirm = true
                    } label: {
                        Label("開始還原", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(manager.isWorking)
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var warningCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("為什麼要備份", systemImage: "exclamationmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.amber)
                Text("這個 App 不使用 iCloud，所有資料只存在這台裝置。刪除 App、換手機或資料庫損毀時，沒有備份就無法救回。建議每次大量匯入之後都匯出一份。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: 動作

    private func handleImport(_ result: Result<[URL], Error>) {
        errorMessage = nil
        message = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard let payload = manager.readPayload(from: url) else {
                errorMessage = "這個檔案無法讀取，請確認是本 App 匯出的備份檔。"
                return
            }
            guard payload.formatVersion <= BackupManager.currentFormatVersion else {
                errorMessage = "這份備份來自較新版本的 App，請先更新後再還原。"
                return
            }
            pendingPayload = payload
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func performRestore() {
        guard let payload = pendingPayload else { return }
        let result = manager.restore(payload: payload,
                                     mode: restoreMode,
                                     restoreSettings: restoreSettings,
                                     context: context,
                                     existing: sessions,
                                     existingGoals: goals)
        message = result.summary
        pendingPayload = nil
        CueService.shared.notify(.success)
    }
}

/// 資料庫異常提示
struct DatabaseNoticeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(Theme.accentWarm.opacity(0.16))
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Theme.accentWarm)
                    }
                    .frame(width: 84, height: 84)
                    .padding(.top, 24)

                    Text("資料庫需要注意")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)

                    GlassCard {
                        Text(DatabaseHealth.message)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let path = DatabaseHealth.quarantinedPath {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("損毀檔案已保留在")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    NavigationLink {
                        BackupView()
                    } label: {
                        Label("前往備份與還原", systemImage: "arrow.up.doc")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button("知道了") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .screenBackground()
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
