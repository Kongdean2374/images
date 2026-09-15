import Foundation

/// 統一的健康 App 同步入口：設定關閉或沒有權限時安全略過。
@MainActor
enum HealthKitSync {

    @discardableResult
    static func syncIfEnabled(_ session: WorkoutSession) async -> Bool {
        guard AppSettings.shared.healthKitEnabled else { return false }
        guard HealthKitManager.shared.isReady else { return false }
        let snapshot = WorkoutSnapshot(session: session)
        let ok = await HealthKitManager.shared.save(snapshot)
        if ok { session.healthKitSynced = true }
        return ok
    }

    /// 批次補傳尚未同步的紀錄
    @discardableResult
    static func syncPending(_ sessions: [WorkoutSession]) async -> Int {
        guard AppSettings.shared.healthKitEnabled, HealthKitManager.shared.isReady else { return 0 }
        var count = 0
        for session in sessions where !session.healthKitSynced {
            let snapshot = WorkoutSnapshot(session: session)
            if await HealthKitManager.shared.save(snapshot) {
                session.healthKitSynced = true
                count += 1
            }
        }
        return count
    }
}
