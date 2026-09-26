import Foundation
import AppIntents
import SwiftUI

/// 用 Siri 或捷徑直接開始某個模式。
/// 開啟 App 並跳到對應畫面，不在背景偷偷開始記錄。
struct StartWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "開始運動"
    static var description = IntentDescription("在 GPS 軌跡記錄器開始一個運動模式")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "模式")
    var mode: WorkoutModeAppEnum

    init() {}

    init(mode: WorkoutModeAppEnum) {
        self.mode = mode
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntentRouter.shared.requestedMode = mode.workoutType
        return .result()
    }
}

/// 快速查今天的步數
struct TodayStepsIntent: AppIntent {
    static var title: LocalizedStringResource = "今天走了幾步"
    static var description = IntentDescription("讀取今日步數")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stats = await PedometerManager.query(from: Calendar.current.startOfDay(for: Date()), to: Date())
        let steps = stats?.numberOfSteps.intValue ?? 0
        let goal = AppSettings.shared.dailyStepGoal
        if steps >= goal {
            return .result(dialog: "今天已經走了 \(steps) 步，超過 \(goal) 步的目標了。")
        }
        return .result(dialog: "今天走了 \(steps) 步，距離 \(goal) 步的目標還差 \(goal - steps) 步。")
    }
}

enum WorkoutModeAppEnum: String, AppEnum {
    case gpsRun, gpsHike, walk, run, treadmill, stairs, ruck
    case lapCounter, shuttleRun, interval, reps, plank, fitnessTest

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "運動模式")

    static var caseDisplayRepresentations: [WorkoutModeAppEnum: DisplayRepresentation] = [
        .gpsRun: "GPS 路跑",
        .gpsHike: "GPS 健行",
        .walk: "走路",
        .run: "跑步",
        .treadmill: "跑步機",
        .stairs: "爬樓梯",
        .ruck: "負重行軍",
        .lapCounter: "營區計圈",
        .shuttleRun: "折返跑",
        .interval: "室內間歇",
        .reps: "原地運動",
        .plank: "棒式撐體",
        .fitnessTest: "體能測驗"
    ]

    var workoutType: WorkoutType {
        switch self {
        case .gpsRun: return .gpsRun
        case .gpsHike: return .gpsHike
        case .walk: return .walk
        case .run: return .run
        case .treadmill: return .treadmill
        case .stairs: return .stairs
        case .ruck: return .ruck
        case .lapCounter: return .lapCounter
        case .shuttleRun: return .shuttleRun
        case .interval: return .indoorInterval
        case .reps: return .indoorReps
        case .plank: return .plank
        case .fitnessTest: return .fitnessTest
        }
    }
}

/// 捷徑開啟 App 後，由首頁讀取這個旗標並開啟對應模式
final class PendingIntentRouter: ObservableObject {
    static let shared = PendingIntentRouter()
    @Published var requestedMode: WorkoutType?
}

struct GPSTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWorkoutIntent(mode: .gpsRun),
                    phrases: ["用 \(.applicationName) 開始跑步",
                              "Start a run with \(.applicationName)"],
                    shortTitle: "開始跑步",
                    systemImageName: "figure.run")
        AppShortcut(intent: StartWorkoutIntent(mode: .lapCounter),
                    phrases: ["用 \(.applicationName) 開始計圈",
                              "Start lap counting with \(.applicationName)"],
                    shortTitle: "開始計圈",
                    systemImageName: "arrow.triangle.capsulepath")
        AppShortcut(intent: TodayStepsIntent(),
                    phrases: ["用 \(.applicationName) 看今天步數",
                              "Today's steps in \(.applicationName)"],
                    shortTitle: "今日步數",
                    systemImageName: "shoeprints.fill")
    }
}
