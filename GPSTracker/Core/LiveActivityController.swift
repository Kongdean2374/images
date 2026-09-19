import Foundation
import ActivityKit

/// 運動進行中的靈動島／鎖定畫面顯示。
/// 系統不支援或使用者關閉時全部安全略過。
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<WorkoutActivityAttributes>?
    private var lastUpdate = Date.distantPast

    private init() {}

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(mode: WorkoutType, usesDistance: Bool) {
        guard AppSettings.shared.liveActivityEnabled, isSupported, activity == nil else { return }
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
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: nil),
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
        guard force || Date().timeIntervalSince(lastUpdate) > 2 else { return }
        lastUpdate = Date()
        let state = WorkoutActivityAttributes.ContentState(elapsed: elapsed,
                                                           distance: distance,
                                                           steps: steps,
                                                           pace: pace,
                                                           statusText: statusText,
                                                           isPaused: isPaused)
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        let finalState = activity.content.state
        self.activity = nil
        Task {
            await activity.end(ActivityContent(state: finalState, staleDate: nil),
                               dismissalPolicy: .immediate)
        }
    }
}
