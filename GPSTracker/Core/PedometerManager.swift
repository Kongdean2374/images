import Foundation
import CoreMotion

/// Core Motion 計步（不需要定位權限，營區、室內、地下室皆可用）。
final class PedometerManager: ObservableObject {
    @Published var steps: Int = 0
    @Published var cadence: Double = 0        // 步/分鐘
    @Published var estimatedDistance: Double? // 公尺（系統估算）
    @Published var floorsAscended: Int = 0
    @Published var floorsDescended: Int = 0
    @Published var pace: Double?              // 秒/公尺（系統估算）
    @Published var isAvailable: Bool = CMPedometer.isStepCountingAvailable()
    @Published var isActive = false

    private let pedometer = CMPedometer()

    static var isFloorCountingAvailable: Bool { CMPedometer.isFloorCountingAvailable() }
    static var isDistanceAvailable: Bool { CMPedometer.isDistanceAvailable() }
    static var isStepCountingAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    func start(from date: Date = Date()) {
        guard CMPedometer.isStepCountingAvailable() else {
            isAvailable = false
            return
        }
        isAvailable = true
        isActive = true
        steps = 0
        cadence = 0
        estimatedDistance = nil
        floorsAscended = 0
        floorsDescended = 0
        pedometer.startUpdates(from: date) { [weak self] data, _ in
            guard let data else { return }
            let steps = data.numberOfSteps.intValue
            let cadence = (data.currentCadence?.doubleValue ?? 0) * 60
            let distance = data.distance?.doubleValue
            let up = data.floorsAscended?.intValue ?? 0
            let down = data.floorsDescended?.intValue ?? 0
            let pace = data.currentPace?.doubleValue
            DispatchQueue.main.async {
                guard let self else { return }
                self.steps = steps
                self.cadence = cadence
                self.estimatedDistance = distance
                self.floorsAscended = up
                self.floorsDescended = down
                self.pace = pace
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
        isActive = false
    }

    /// 回溯查詢一段期間的計步資料（即使 App 沒開，系統也有記錄）
    static func query(from start: Date, to end: Date) async -> CMPedometerData? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        let pedometer = CMPedometer()
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
