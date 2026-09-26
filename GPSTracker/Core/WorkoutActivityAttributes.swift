import Foundation
import ActivityKit

/// 靈動島／鎖定畫面即時活動的資料結構（App 與 Widget 共用同一份定義）。
struct WorkoutActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var elapsed: TimeInterval
        var distance: Double
        var steps: Int
        var pace: Double?
        var statusText: String
        var isPaused: Bool
    }

    var modeName: String
    var symbolName: String
    var startDate: Date
    var usesDistance: Bool
}
