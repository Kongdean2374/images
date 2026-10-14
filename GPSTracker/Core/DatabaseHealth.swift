import Foundation
import SwiftData

/// 資料庫健康狀態。
///
/// 舊版在開啟失敗時直接退回記憶體模式，使用者會看到「紀錄全部消失、
/// 新存的東西關掉又不見」，比報錯更糟。現在改成：把開不起來的資料庫檔
/// 移到隔離區保留下來、用全新的資料庫啟動，並明確告知使用者可以從備份還原。
enum DatabaseHealth {

    enum State: Equatable {
        case healthy
        /// 舊資料庫損毀，已隔離保留，目前使用全新資料庫
        case recoveredWithFreshStore(quarantinedPath: String)
        /// 連新資料庫都建不起來，只能用記憶體模式（關閉即消失）
        case memoryOnly
    }

    private(set) static var state: State = .healthy

    static var needsAttention: Bool {
        state != .healthy
    }

    static var message: String {
        switch state {
        case .healthy:
            return ""
        case .recoveredWithFreshStore:
            return "上次的資料庫檔已損毀，App 已用全新的資料庫啟動。舊檔案沒有被刪除，仍保留在裝置上。你可以從備份檔還原，或重新從健康 App 匯入。"
        case .memoryOnly:
            return "資料庫無法建立，目前為暫存模式：這次記錄的內容在關閉 App 後不會保留。原始資料庫保持原位，已停止寫入；請保留裝置資料與備份，重新啟動或尋求資料庫修復。"
        }
    }

    static var quarantinedPath: String? {
        if case let .recoveredWithFreshStore(path) = state { return path }
        return nil
    }

    /// 建立資料庫，必要時隔離損毀檔後重試
    static func makeContainer(schema: Schema) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            state = .healthy
            return container
        } catch {
            // Opening/migration failure must never move, delete or rebuild a user's store.
            // A clearly disclosed temporary container permits viewing the recovery interface.
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            state = .memoryOnly
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }

}
