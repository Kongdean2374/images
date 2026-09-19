import Foundation
import HealthKit
import UserNotifications

/// 背景更新：即使 App 沒開，健康 App 有新資料時系統會喚醒我們，
/// 用來（1）自動匯入其他 App 的新訓練（2）達成步數／距離目標時推播。
final class HealthBackgroundMonitor {
    static let shared = HealthBackgroundMonitor()

    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private var started = false
    private let defaults = UserDefaults.standard

    private init() {}

    var isRunning: Bool { started }

    // MARK: 啟動

    func start() {
        guard HKHealthStore.isHealthDataAvailable(), !started else { return }
        guard AppSettings.shared.backgroundUpdates else { return }
        started = true

        observe(HKQuantityType(.stepCount), frequency: .hourly) { [weak self] in
            await self?.checkDailyGoals()
        }
        observe(HKQuantityType(.distanceWalkingRunning), frequency: .hourly) { [weak self] in
            await self?.checkDailyGoals()
        }
        observe(HKObjectType.workoutType(), frequency: .immediate) { [weak self] in
            await self?.handleNewWorkouts()
        }
    }

    func stop() {
        for query in observers {
            store.stop(query)
        }
        observers.removeAll()
        started = false
        disableBackgroundDelivery()
    }

    private func observe(_ type: HKSampleType,
                         frequency: HKUpdateFrequency,
                         handler: @escaping () async -> Void) {
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, _ in
            Task {
                await handler()
                completion()
            }
        }
        store.execute(query)
        observers.append(query)

        store.enableBackgroundDelivery(for: type, frequency: frequency) { _, _ in
            // 沒有權限時安靜略過，前景功能不受影響
        }
    }

    private func disableBackgroundDelivery() {
        store.disableAllBackgroundDelivery { _, _ in }
    }

    // MARK: 每日目標

    /// 讀今天的步數與距離，達標時推播（每個里程碑每天只提醒一次）
    func checkDailyGoals() async {
        let start = Calendar.current.startOfDay(for: Date())
        let steps = await sum(HKQuantityType(.stepCount), unit: .count(), from: start)
        let distance = await sum(HKQuantityType(.distanceWalkingRunning), unit: .meter(), from: start)

        let settings = AppSettings.shared
        let stepGoal = max(1, settings.dailyStepGoal)
        let distanceGoal = max(0.1, settings.dailyDistanceGoal) * 1000

        if let steps {
            let value = Int(steps)
            if value >= stepGoal {
                notifyOnce(key: "stepsGoal",
                           title: "步數目標達成 🎉",
                           body: "今天已經走了 \(value) 步，超過 \(stepGoal) 步的目標。")
            } else if Double(value) >= Double(stepGoal) * 0.5 {
                notifyOnce(key: "stepsHalf",
                           title: "已完成一半",
                           body: "今天走了 \(value) 步，距離目標還差 \(stepGoal - value) 步。")
            }
        }

        if let distance, distance >= distanceGoal {
            notifyOnce(key: "distanceGoal",
                       title: "距離目標達成 🎯",
                       body: String(format: "今天累積 %.2f 公里，達成 %.1f 公里的目標。",
                                    distance / 1000, distanceGoal / 1000))
        }
    }

    private func sum(_ type: HKQuantityType, unit: HKUnit, from start: Date) async -> Double? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: type,
                                          quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    // MARK: 新訓練

    private func handleNewWorkouts() async {
        guard AppSettings.shared.autoImportHealth else { return }
        let result = await HealthKitImporter.shared.importNewInBackground()
        guard result.imported > 0 else { return }
        let sources = result.sources.keys.sorted().joined(separator: "、")
        notify(identifier: "importedWorkouts-\(UUID().uuidString)",
               title: "已匯入 \(result.imported) 筆新訓練",
               body: sources.isEmpty ? "來自健康 App" : "來自 \(sources)")
    }

    // MARK: 通知

    /// 同一個里程碑每天只提醒一次
    private func notifyOnce(key: String, title: String, body: String) {
        let today = Self.dayKey.string(from: Date())
        let storageKey = "notified.\(key)"
        if defaults.string(forKey: storageKey) == today { return }
        defaults.set(today, forKey: storageKey)
        notify(identifier: "\(key)-\(today)", title: title, body: body)
    }

    private func notify(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
