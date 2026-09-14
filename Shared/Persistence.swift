import Foundation
import SwiftData

/// SwiftData 容器建立。
/// 預設純本機；使用者在設定頁打開「iCloud 同步」後改用 CloudKit 私有資料庫（可選功能 §8）。
/// 若裝置／憑證沒有 iCloud 權限，會自動退回本機，不會讓 App 開不起來。
enum Persistence {
    static let schema = Schema([
        Expense.self,
        SpendingCategory.self,
        EmotionTag.self,
        BudgetSetting.self,
        FixedExpense.self
    ])

    /// 這次啟動實際有沒有跑在 CloudKit 上（設定頁顯示用）。
    private(set) static var isUsingCloudKit = false

    static func makeContainer(cloudSyncEnabled: Bool = AppSettings.cloudSyncEnabled) -> ModelContainer {
        let url = AppGroup.storeURL

        if cloudSyncEnabled {
            let cloudConfig = ModelConfiguration(
                schema: schema,
                url: url,
                cloudKitDatabase: .private(AppGroup.cloudKitContainerID)
            )
            if let container = try? ModelContainer(for: schema, configurations: cloudConfig) {
                isUsingCloudKit = true
                return container
            }
        }

        let localConfig = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: localConfig) {
            isUsingCloudKit = false
            return container
        }

        // 最後手段：記憶體容器，至少讓 App 能開起來並顯示錯誤。
        let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        isUsingCloudKit = false
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: memoryConfig)
    }
}

/// 讓 App Intents（Siri / Live Activity 按鈕）也能拿到同一個容器。
@MainActor
enum AppContainer {
    static let shared: ModelContainer = Persistence.makeContainer()
    static var context: ModelContext { ModelContext(shared) }
}
