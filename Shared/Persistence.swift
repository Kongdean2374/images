import Foundation
import SwiftData

/// 同步狀態（設定頁顯示用）
enum SyncStatus: String {
    case local            // 純本機
    case cloud            // 已連上 iCloud
    case cloudUnavailable // 想開但開不成（沒帳號 / 沒權限），已自動退回本機
}

/// SwiftData 容器建立。
///
/// ⚠️ 重要：側載自簽的 App 通常沒有 iCloud entitlement，SwiftData 建立 CloudKit 容器時
/// 丟的是 Objective-C 例外，Swift 的 `try?` 攔不住 → 會直接閃退，而且每次開都掛在同一行。
/// 所以這裡用三道防線：
///   1. 開容器前先確認裝置真的有可用的 iCloud 帳號（`ubiquityIdentityToken`）
///   2. 嘗試前先在 UserDefaults 插旗；成功才拔旗。下次啟動看到旗子還在 = 上次是閃退，
///      自動關掉 iCloud 同步並用本機模式開起來（自我修復，不會卡在閃退迴圈）
///   3. 本機與 iCloud 用「兩個不同的資料庫檔」，CloudKit 失敗不會污染本機那份
enum Persistence {
    static let schema = Schema([
        Expense.self,
        SpendingCategory.self,
        EmotionTag.self,
        BudgetSetting.self,
        FixedExpense.self
    ])

    private(set) static var status: SyncStatus = .local

    static var isUsingCloudKit: Bool { status == .cloud }

    // MARK: - Store 位置

    static var localStoreURL: URL { AppGroup.containerURL.appendingPathComponent("MoneyLeft.store") }
    static var cloudStoreURL: URL { AppGroup.containerURL.appendingPathComponent("MoneyLeft-cloud.store") }

    static func storeExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 這台裝置現在有沒有登入 iCloud（沒有 entitlement 時也會是 nil，正好當成前置檢查）
    static var iCloudAccountAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    // MARK: - 建立容器

    static func makeContainer() -> ModelContainer {
        _ = ensureDirectory()

        // 防線 2：上次插的旗子還在 → 代表上次啟動時在 CloudKit 這段掛掉了
        if AppSettings.cloudLaunchInProgress {
            AppSettings.cloudLaunchInProgress = false
            AppSettings.cloudSyncEnabled = false
            AppSettings.cloudFailureNote = "上次啟用 iCloud 同步後 App 無法啟動，已自動切回本機模式，資料沒有遺失。"
        }

        if AppSettings.cloudSyncEnabled {
            if let container = makeCloudContainer() {
                status = .cloud
                AppSettings.cloudFailureNote = nil
                return container
            }
            // 開不起來 → 關掉設定，走本機
            AppSettings.cloudSyncEnabled = false
            status = .cloudUnavailable
        }

        if let container = makeLocalContainer() {
            if status != .cloudUnavailable { status = .local }
            return container
        }

        // 真的都失敗才用記憶體容器，至少 App 開得起來
        status = .local
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return (try? ModelContainer(for: schema, configurations: memory))
            ?? ModelContainer.emergency()
    }

    /// 嘗試建立 CloudKit 容器；任何一關沒過都回 nil（呼叫端退回本機）
    static func makeCloudContainer() -> ModelContainer? {
        // 防線 1
        guard iCloudAccountAvailable else {
            AppSettings.cloudFailureNote = "這台裝置沒有可用的 iCloud 帳號，或這份簽名沒有 iCloud 權限（免費 Apple ID 自簽就會這樣），已維持本機模式。"
            return nil
        }

        AppSettings.cloudLaunchInProgress = true   // 插旗
        defer { AppSettings.cloudLaunchInProgress = false }

        let config = ModelConfiguration(
            schema: schema,
            url: cloudStoreURL,
            cloudKitDatabase: .private(AppGroup.cloudKitContainerID)
        )
        guard let container = try? ModelContainer(for: schema, configurations: config),
              smokeTest(container) else {
            AppSettings.cloudFailureNote = "無法建立 iCloud 資料容器，已維持本機模式。"
            return nil
        }
        return container
    }

    static func makeLocalContainer() -> ModelContainer? {
        let config = ModelConfiguration(schema: schema, url: localStoreURL, cloudKitDatabase: .none)
        guard let container = try? ModelContainer(for: schema, configurations: config),
              smokeTest(container) else { return nil }
        return container
    }

    /// 真的讀一次，確認 store 有掛上去（ModelContainer 建得出來不代表能用）
    private static func smokeTest(_ container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        return (try? context.fetchCount(FetchDescriptor<SpendingCategory>())) != nil
    }

    @discardableResult
    private static func ensureDirectory() -> Bool {
        let base = AppGroup.containerURL
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return true
    }
}

private extension ModelContainer {
    /// 連記憶體容器都建不起來時的最後保險（理論上不會走到）
    static func emergency() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: Expense.self, configurations: config)
    }
}

/// 讓 App Intents（Siri / 動態島按鈕）拿到同一個容器。
@MainActor
enum AppContainer {
    static let shared: ModelContainer = Persistence.makeContainer()
    static var context: ModelContext { ModelContext(shared) }
}
