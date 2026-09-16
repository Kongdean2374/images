import SwiftUI
import SwiftData
import CryptoKit
import UniformTypeIdentifiers

/// 端對端加密統計：金鑰管理、金鑰匯出／匯入、密文同步。
/// 資料在離開這支手機之前就已經加密，伺服器全程只拿得到密文。
struct EncryptionView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var keys = DataKeyManager.shared
    @StateObject private var sync = StatsSyncService.shared

    @State private var showExport = false
    @State private var showImport = false
    @State private var showDeleteConfirm = false
    @State private var exportURL: URL?
    @State private var password = ""
    @State private var passwordConfirm = ""
    @State private var importPassword = ""
    @State private var pendingEnvelope: KeyTransfer.KeyEnvelope?
    @State private var message: String?
    @State private var isError = false
    @State private var selfTestResult: String?
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                flowCard
                keyCard
                if keys.hasKey {
                    exportCard
                }
                importCard
                syncCard
                if let selfTestResult { selfTestCard(selfTestResult) }
                explainCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .screenBackground()
        .navigationTitle("端對端加密")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { keys.refresh() }
        .alert(isError ? "沒有成功" : "完成",
               isPresented: Binding(get: { message != nil },
                                    set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .sheet(isPresented: $showExport) { exportSheet }
        .fileImporter(isPresented: $showImport,
                      allowedContentTypes: [.json, .data],
                      allowsMultipleSelection: false) { result in
            handleImportFile(result)
        }
        .sheet(item: Binding(get: { pendingEnvelope.map { EnvelopeBox(envelope: $0) } },
                             set: { if $0 == nil { pendingEnvelope = nil } })) { box in
            importSheet(box.envelope)
        }
    }

    // MARK: 流程圖

    private var flowCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("資料怎麼被保護", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                VStack(spacing: 0) {
                    flowStep(index: 1, icon: "key.fill", tint: Theme.accent,
                             title: "手機本機生成金鑰 Key A",
                             detail: "256-bit，存在 iOS Keychain，永不外流")
                    flowLine
                    flowStep(index: 2, icon: "lock.fill", tint: Theme.mint,
                             title: "上傳前先加密",
                             detail: "AES-256-GCM，離開手機時已經是密文")
                    flowLine
                    flowStep(index: 3, icon: "externaldrive.fill", tint: Theme.amber,
                             title: "伺服器只存密文",
                             detail: "伺服器沒有 Key A，就算被入侵也讀不到內容")
                    flowLine
                    flowStep(index: 4, icon: "arrow.down.doc.fill", tint: Theme.violet,
                             title: "下載後在本機解密",
                             detail: "解密永遠只發生在你自己的裝置上")
                }
            }
        }
    }

    private func flowStep(index: Int, icon: String, tint: Color,
                          title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index). \(title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var flowLine: some View {
        HStack {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 2, height: 14)
                .padding(.leading, 16)
            Spacer()
        }
    }

    // MARK: 金鑰狀態

    private var keyCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("資料金鑰 Key A", systemImage: "key.horizontal.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(keys.hasKey ? "已啟用" : "未建立")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(keys.hasKey ? Theme.mint : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill((keys.hasKey ? Theme.mint : Color.gray).opacity(0.16)))
                }

                if keys.hasKey {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("金鑰指紋")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                        Text(keys.fingerprint)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        if let created = keys.createdAt {
                            Text("建立於 \(created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text("兩台裝置的指紋一樣，代表用的是同一把金鑰。")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            selfTestResult = sync.selfTest()
                        } label: {
                            Label("執行加解密自我測試", systemImage: "checkmark.seal")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("刪除金鑰", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accentWarm)
                    }
                    .confirmationDialog("確定要刪除資料金鑰？",
                                        isPresented: $showDeleteConfirm,
                                        titleVisibility: .visible) {
                        Button("刪除金鑰", role: .destructive) {
                            keys.deleteKey()
                            report("金鑰已刪除", error: false)
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("刪除後，已經上傳到伺服器的密文將永久無法解密。除非你已經匯出備份，否則這個動作無法復原。")
                    }
                } else {
                    Text("還沒有金鑰。建立之後，統計資料才會在上傳前先加密。金鑰只會存在這支手機的 Keychain 裡。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        do {
                            try keys.ensureKey()
                            report("已在本機生成 256-bit 金鑰", error: false)
                        } catch {
                            report(error.localizedDescription, error: true)
                        }
                    } label: {
                        Label("在這支手機生成金鑰", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private func selfTestCard(_ text: String) -> some View {
        GlassCard(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: text.hasPrefix("通過") ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(text.hasPrefix("通過") ? Theme.mint : Theme.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("自我測試")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 匯出

    private var exportCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("匯出金鑰（換手機／給信任的人）", systemImage: "square.and.arrow.up.on.square")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("匯出檔不是金鑰原文：會先用你設定的密碼經過 PBKDF2（\(KeyTransfer.defaultIterations.formatted()) 輪）衍生出包裝金鑰，再用 AES-256-GCM 把 Key A 包起來。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    password = ""
                    passwordConfirm = ""
                    showExport = true
                } label: {
                    Label("設定密碼並匯出", systemImage: "lock.doc")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var exportSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("匯出密碼（至少 8 字）", text: $password)
                    SecureField("再輸入一次", text: $passwordConfirm)
                    strengthBar
                } header: {
                    Text("保護密碼")
                } footer: {
                    Text("忘記密碼就無法從這個檔案還原金鑰，而且沒有任何後門可以救回來。")
                }

                Section {
                    Label("密碼請走另外的管道給對方", systemImage: "exclamationmark.bubble.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                    Text("例如檔案用雲端傳、密碼用當面講或電話講。檔案跟密碼一起外流，加密就等於沒做。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }

                Section {
                    Button {
                        performExport()
                    } label: {
                        if working {
                            HStack { ProgressView(); Text("加密中⋯") }
                        } else {
                            Text("產生金鑰檔")
                        }
                    }
                    .disabled(working || password.count < 8 || password != passwordConfirm)

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享金鑰檔", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("匯出金鑰")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("關閉") { showExport = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var strengthBar: some View {
        let strength = KeyTransfer.passwordStrength(password)
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(strength > 0.7 ? Theme.mint : (strength > 0.4 ? Theme.amber : Theme.accentWarm))
                        .frame(width: geo.size.width * strength)
                }
            }
            .frame(height: 6)
            Text(strength > 0.7 ? "強度：足夠" : (strength > 0.4 ? "強度：普通，建議再長一點" : "強度：太弱"))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func performExport() {
        guard let key = keys.currentKey() else {
            report("尚未建立金鑰", error: true)
            return
        }
        working = true
        let secret = password
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let envelope = try KeyTransfer.export(key: key, password: secret)
                let url = try KeyTransfer.writeFile(envelope)
                DispatchQueue.main.async {
                    working = false
                    exportURL = url
                    report("金鑰檔已產生，用下面的分享按鈕傳出去", error: false)
                }
            } catch {
                DispatchQueue.main.async {
                    working = false
                    report(error.localizedDescription, error: true)
                }
            }
        }
    }

    // MARK: 匯入

    private var importCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("匯入金鑰", systemImage: "square.and.arrow.down.on.square")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("從舊手機或對方那邊拿到 .gtkey 檔後，在這裡輸入密碼就能還原同一把 Key A，接著就能解開伺服器上的密文。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    showImport = true
                } label: {
                    Label("選擇金鑰檔", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func handleImportFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pendingEnvelope = try KeyTransfer.decode(data)
                importPassword = ""
            } catch {
                report(error.localizedDescription, error: true)
            }
        case .failure(let error):
            report(error.localizedDescription, error: true)
        }
    }

    private func importSheet(_ envelope: KeyTransfer.KeyEnvelope) -> some View {
        NavigationStack {
            Form {
                Section("這個檔案") {
                    LabeledContent("格式版本", value: "v\(envelope.version)")
                    LabeledContent("衍生演算法", value: envelope.kdf)
                    LabeledContent("迭代次數", value: envelope.iterations.formatted())
                    LabeledContent("金鑰指紋", value: envelope.fingerprint)
                        .font(.system(.body, design: .monospaced))
                    LabeledContent("匯出時間",
                                   value: envelope.exportedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    SecureField("檔案的保護密碼", text: $importPassword)
                    Button("解開並套用這把金鑰") {
                        applyImport(envelope)
                    }
                    .disabled(importPassword.isEmpty || working)
                } footer: {
                    Text("匯入之後會覆蓋這支手機現有的金鑰。若原本的金鑰還有未備份的密文資料，請先匯出備份。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("匯入金鑰")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { pendingEnvelope = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func applyImport(_ envelope: KeyTransfer.KeyEnvelope) {
        working = true
        let secret = importPassword
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let key = try KeyTransfer.importKey(from: envelope, password: secret)
                try DataKeyManager.shared.replaceKey(with: key)
                DispatchQueue.main.async {
                    working = false
                    pendingEnvelope = nil
                    report("金鑰已匯入，指紋 \(DataKeyManager.shared.fingerprintOfCurrentKey)", error: false)
                }
            } catch {
                DispatchQueue.main.async {
                    working = false
                    report(error.localizedDescription, error: true)
                }
            }
        }
    }

    // MARK: 同步

    private var syncCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("密文同步（選用）", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                Toggle("啟用同步", isOn: $sync.enabled)
                    .tint(Theme.accent)

                VStack(alignment: .leading, spacing: 5) {
                    Text("伺服器位址（必須是 HTTPS）")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("https://api.你的網域/v1", text: $sync.baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                }

                if !sync.baseURLText.isEmpty && !sync.isConfigured {
                    Label("這個位址不是有效的 HTTPS 網址，不接受明文 HTTP。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.amber)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await uploadStats() }
                    } label: {
                        Label("上傳", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!sync.enabled || !sync.isConfigured || !keys.hasKey)

                    Button {
                        Task { await downloadStats() }
                    } label: {
                        Label("下載", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!sync.enabled || !sync.isConfigured || !keys.hasKey)
                }

                statusRow

                if let last = sync.lastSyncAt {
                    Text("上次同步：\(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }

                Text("同步只會送出彙總統計（次數、距離、時間、熱量），不含路線座標。伺服器端尚未部署前，這裡維持關閉即可，App 其他功能完全不受影響。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch sync.status {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.mint)
        case .failure(let text):
            Label(text, systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.accentWarm)
        }
    }

    private func uploadStats() async {
        do {
            try await sync.upload(buildPacket())
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    private func downloadStats() async {
        do {
            let packet = try await sync.fetchLatest()
            report("已解密：\(packet.totalWorkouts) 筆訓練、\(String(format: "%.1f", packet.totalDistance / 1000)) 公里", error: false)
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    private func buildPacket() -> StatsPacket {
        let calendar = Calendar.current
        let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                                    from: Date())) ?? Date()
        let week = sessions.filter { $0.startDate >= weekStart }
        var byType: [String: Int] = [:]
        for session in sessions {
            byType[session.type.rawValue, default: 0] += 1
        }
        return StatsPacket(generatedAt: Date(),
                           totalWorkouts: sessions.count,
                           totalDistance: sessions.reduce(0) { $0 + ($1.totalDistance ?? 0) },
                           totalDuration: sessions.reduce(0) { $0 + $1.duration },
                           totalCalories: sessions.reduce(0) { $0 + ($1.calories ?? 0) },
                           weeklyDistance: week.reduce(0) { $0 + ($1.totalDistance ?? 0) },
                           weeklyDuration: week.reduce(0) { $0 + $1.duration },
                           longestDistance: sessions.compactMap { $0.totalDistance }.max() ?? 0,
                           bestPace: sessions.compactMap { $0.averagePace }.filter { $0 > 0 }.min(),
                           currentStreak: 0,
                           byType: byType)
    }

    // MARK: 說明

    private var explainCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("安全性摘要", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                row("傳輸中", "只走 HTTPS", "防半路被攔截偷看")
                row("伺服器儲存", "只存密文，伺服器沒有 Key A", "防伺服器被入侵")
                row("金鑰匯出", "使用者密碼 + PBKDF2 + AES-256-GCM", "防檔案外流導致金鑰外洩")
                row("金鑰分享", "密碼走另外的管道傳", "防檔案與密碼一起外流")
            }
        }
    }

    private func row(_ title: String, _ how: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(how)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            Text(why)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func report(_ text: String, error: Bool) {
        isError = error
        message = text
        keys.refresh()
    }
}

/// 讓 KeyEnvelope 能用在 sheet(item:)
private struct EnvelopeBox: Identifiable {
    let envelope: KeyTransfer.KeyEnvelope
    var id: String { envelope.fingerprint + envelope.salt }
}
