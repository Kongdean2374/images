import Foundation
import SwiftData

/// SwiftData 容器建立 —— 純本機，沒有任何雲端、沒有任何連網。
enum Persistence {
    static let schema = Schema([
        Expense.self,
        SpendingCategory.self,
        EmotionTag.self,
        BudgetSetting.self,
        FixedExpense.self,
        PhraseMapping.self
    ])

    static var storeURL: URL { AppGroup.containerURL.appendingPathComponent("MoneyLeft.store") }

    /// v1 曾經啟用過 iCloud 時留下的資料庫，開 App 時會把紀錄搬回本機再封存。
    static var legacyCloudStoreURL: URL { AppGroup.containerURL.appendingPathComponent("MoneyLeft-cloud.store") }

    static func makeContainer() -> ModelContainer {
        AppSettings.purgeLegacyCloudKeys()
        try? FileManager.default.createDirectory(at: AppGroup.containerURL, withIntermediateDirectories: true)

        if let container = makeLocalContainer() {
            migrateLegacyCloudStoreIfNeeded(into: container)
            return container
        }

        // 本機檔案壞掉才會走到這：改用記憶體容器，至少 App 開得起來
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: memory)
    }

    static func makeLocalContainer() -> ModelContainer? {
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        guard let container = try? ModelContainer(for: schema, configurations: config),
              smokeTest(container) else { return nil }
        return container
    }

    private static func smokeTest(_ container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        return (try? context.fetchCount(FetchDescriptor<SpendingCategory>())) != nil
    }

    /// 把舊的 iCloud 資料庫內容搬回本機，然後把舊檔改名封存（不直接刪，留一次後路）。
    private static func migrateLegacyCloudStoreIfNeeded(into container: ModelContainer) {
        guard !AppSettings.didMigrateLegacyCloudStore else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyCloudStoreURL.path) else {
            AppSettings.didMigrateLegacyCloudStore = true
            return
        }

        defer { AppSettings.didMigrateLegacyCloudStore = true }

        let legacyConfig = ModelConfiguration(schema: schema, url: legacyCloudStoreURL, cloudKitDatabase: .none)
        guard let legacyContainer = try? ModelContainer(for: schema, configurations: legacyConfig) else { return }

        let source = ModelContext(legacyContainer)
        let target = ModelContext(container)
        let copied = StoreCopier.copyIfDestinationEmpty(from: source, to: target)

        if copied > 0 {
            AppSettings.legacyMigrationNote = "已把 \(copied) 筆原本存在 iCloud 的紀錄搬回本機，iCloud 同步功能已移除。"
        }

        // 封存舊檔（含 -wal / -shm）
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: legacyCloudStoreURL.path + suffix)
            let to = URL(fileURLWithPath: legacyCloudStoreURL.path + suffix + ".bak")
            try? fileManager.removeItem(at: to)
            try? fileManager.moveItem(at: from, to: to)
        }
    }
}

/// 讓 App Intents（Siri / 動態島 / Widget 按鈕）拿到同一個容器。
@MainActor
enum AppContainer {
    static let shared: ModelContainer = Persistence.makeContainer()
    static var context: ModelContext { ModelContext(shared) }
}
