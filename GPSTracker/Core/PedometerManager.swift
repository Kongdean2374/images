import Foundation
import CoreMotion

/// Core Motion 計步（不需要定位權限，營區、室內皆可用）。
final class PedometerManager: ObservableObject {
    @Published private(set) var steps: Int = 0
    @Published private(set) var cadence: Double = 0        // 步/分鐘
    @Published private(set) var estimatedDistance: Double? // 公尺
    @Published private(set) var isAvailable: Bool = CMPedometer.isStepCountingAvailable()
    @Published private(set) var isActive = false

    private let pedometer = CMPedometer()

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
        pedometer.startUpdates(from: date) { [weak self] data, _ in
            guard let data else { return }
            let steps = data.numberOfSteps.intValue
            let cadence = (data.currentCadence?.doubleValue ?? 0) * 60
            let distance = data.distance?.doubleValue
            DispatchQueue.main.async {
                guard let self else { return }
                self.steps = steps
                self.cadence = cadence
                self.estimatedDistance = distance
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
        isActive = false
    }
}
