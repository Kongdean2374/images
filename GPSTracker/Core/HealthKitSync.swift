import Foundation

/// 統一的健康 App 同步入口：設定關閉或沒有權限時安全略過。
@MainActor
enum HealthKitSync {

    @discardableResult
    static func syncIfEnabled(_ session: WorkoutSession) async -> Bool {
        guard AppSettings.shared.healthKitEnabled else { return false }
        guard HealthKitManager.shared.isReady else { return false }
        guard !session.isImported else { return false }
        let snapshot = WorkoutSnapshot(session: session)
        guard let uuid = await HealthKitManager.shared.save(snapshot) else { return false }
        session.healthKitSynced = true
        session.healthKitUUID = uuid
        return true
    }

    /// 批次補傳尚未同步的紀錄
    @discardableResult
    static func syncPending(_ sessions: [WorkoutSession]) async -> Int {
        guard AppSettings.shared.healthKitEnabled, HealthKitManager.shared.isReady else { return 0 }
        var count = 0
        for session in sessions where !session.healthKitSynced && !session.isImported {
            let snapshot = WorkoutSnapshot(session: session)
            if let uuid = await HealthKitManager.shared.save(snapshot) {
                session.healthKitSynced = true
                session.healthKitUUID = uuid
                count += 1
            }
        }
        return count
    }
}
