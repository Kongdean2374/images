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
            return "資料庫無法建立，目前為暫存模式：這次記錄的內容在關閉 App 後不會保留。請重新啟動 App，若仍相同，建議重裝並從備份還原。"
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
            // 第一次失敗：把損毀的檔案移開，保留原始資料以便日後救援
            let quarantined = quarantineStoreFiles()
            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                state = .recoveredWithFreshStore(quarantinedPath: quarantined ?? "未知位置")
                return container
            } catch {
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                state = .memoryOnly
                // 記憶體模式若再失敗就真的無法運作，這裡是最後一道
                return (try? ModelContainer(for: schema, configurations: [memory]))
                    ?? (try! ModelContainer(for: schema, configurations: [memory]))
            }
        }
    }

    /// 把 default.store 及其附屬檔案改名保留
    private static func quarantineStoreFiles() -> String? {
        let manager = FileManager.default
        guard let supportDirectory = manager.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let stamp = DataExporter.stamp()
        var movedTo: String?

        for suffix in ["", "-wal", "-shm"] {
            let source = supportDirectory.appendingPathComponent("default.store\(suffix)")
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = supportDirectory
                .appendingPathComponent("corrupted-\(stamp)-default.store\(suffix)")
            do {
                try manager.moveItem(at: source, to: destination)
                if suffix.isEmpty { movedTo = destination.path }
            } catch {
                // 移不動就試著直接刪除主檔，至少讓 App 能開起來
                if suffix.isEmpty { try? manager.removeItem(at: source) }
            }
        }
        return movedTo
    }
}
