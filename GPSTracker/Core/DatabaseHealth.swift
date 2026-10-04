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
            return "資料庫暫時無法開啟，原始檔案完整保留。本次不接受正式儲存或健康匯入；請先解鎖裝置、確認可用空間後重開。請勿移除 App。"
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
            // An opening error may be migration, file protection or disk pressure,
            // not corruption. Leave the store and WAL untouched for recovery.
            state = .memoryOnly
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do { return try ModelContainer(for: schema, configurations: [memory]) }
            catch { fatalError("Unable to open a safe temporary store: \(error)") }
        }
    }

}
