import Foundation
import SwiftData

/// 統一的紀錄儲存入口。
///
/// 以前各畫面都是 `context.insert(session); try? context.save()`，
/// `try?` 會把錯誤整個吞掉——磁碟滿了、資料庫損毀時，使用者只會看到
/// 運動「好像存好了」，實際上什麼都沒留下。這裡改成明確回報成功與否。
@MainActor
enum SessionSaver {

    enum Result {
        case saved
        case failed(String)
    }

    /// 存入資料庫。成功才會清掉進行中的自動存檔。
    @discardableResult
    static func save(_ session: WorkoutSession,
                     context: ModelContext,
                     clearsAutosave: Bool = true) -> Result {
        context.insert(session)
        do {
            try context.save()
            if clearsAutosave {
                // 只有確定寫進資料庫了，才放心刪掉自動存檔的備份
                ActiveWorkoutStore.shared.clear()
            }
            return .saved
        } catch {
            // 儲存失敗時保留自動存檔，下次開啟 App 還救得回來
            context.rollback()
            DiagnosticsLog.shared.log(.error, category: "storage", "紀錄寫入資料庫失敗",
                                      detail: ["錯誤": error.localizedDescription,
                                               "運動": session.type.displayName,
                                               "距離": String(format: "%.0f m", session.totalDistance ?? 0)])
            return .failed(error.localizedDescription)
        }
    }
}
