import Foundation
import ActivityKit

/// 運動進行中的靈動島／鎖定畫面顯示。
/// 系統不支援或使用者關閉時全部安全略過。
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<WorkoutActivityAttributes>?
    private var lastUpdate = Date.distantPast
    /// 背景時大幅降低更新頻率，避免被系統以「背景用量過高」終止
    var isInBackground = false

    private init() {}

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 卡住的靈動島清除器。
    ///
    /// Live Activity 的生命週期由系統管理，App 被砍掉或從多工滑掉時
    /// 不會自動結束，所以會一直卡在靈動島上。每次啟動時把所有殘留的
    /// 活動結束掉，就不會再出現「怎麼用都還在」的狀況。
    func endStaleActivities() {
        Task {
            for activity in Activity<WorkoutActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await MainActor.run { self.activity = nil }
        }
    }

    /// 結束所有活動，包含這次持有的那一個
    func endAll() {
        activity = nil
        Task {
            for activity in Activity<WorkoutActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func start(mode: WorkoutType, usesDistance: Bool) {
        guard AppSettings.shared.liveActivityEnabled, isSupported else { return }
        // 開始新的之前先把殘留的清掉，避免疊一堆
        if activity != nil || !Activity<WorkoutActivityAttributes>.activities.isEmpty {
            endAll()
        }
        let attributes = WorkoutActivityAttributes(modeName: mode.displayName,
                                                   symbolName: mode.systemImage,
                                                   startDate: Date(),
                                                   usesDistance: usesDistance)
        let state = WorkoutActivityAttributes.ContentState(elapsed: 0,
                                                           distance: 0,
                                                           steps: 0,
                                                           pace: nil,
                                                           statusText: "記錄中",
                                                           isPaused: false)
        do {
            // 設定 staleDate：就算 App 被砍掉，系統也會在這個時間之後
            // 自己把它收起來，不會永遠卡在靈動島上
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state,
                                                                     staleDate: Date().addingTimeInterval(900)),
                                            pushType: nil)
        } catch {
            activity = nil
        }
    }

    /// 節流更新，避免太頻繁刷新
    func update(elapsed: TimeInterval,
                distance: Double,
                steps: Int,
                pace: Double?,
                statusText: String,
                isPaused: Bool,
                force: Bool = false) {
        guard let activity else { return }
        let minimumInterval: TimeInterval = isInBackground ? 15 : 2
        guard force || Date().timeIntervalSince(lastUpdate) > minimumInterval else { return }
        lastUpdate = Date()
        let state = WorkoutActivityAttributes.ContentState(elapsed: elapsed,
                                                           distance: distance,
                                                           steps: steps,
                                                           pace: pace,
                                                           statusText: statusText,
                                                           isPaused: isPaused)
        Task {
            // 每次更新都把過期時間往後推 15 分鐘。
            // App 一旦停止更新（被砍掉），15 分鐘後系統就會自動收掉。
            await activity.update(ActivityContent(state: state,
                                                  staleDate: Date().addingTimeInterval(900)))
        }
    }

    func end() {
        self.activity = nil
        Task {
            // 連同任何殘留的一起結束，確保靈動島一定清乾淨
            for activity in Activity<WorkoutActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
