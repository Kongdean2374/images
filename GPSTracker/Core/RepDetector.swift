import Foundation
import CoreMotion

/// 原地運動（開合跳、波比跳）次數偵測：加速度計 + 陀螺儀峰值偵測。
final class RepDetector: ObservableObject {
    @Published private(set) var repCount = 0
    @Published private(set) var magnitude: Double = 0
    @Published private(set) var isRunning = false
    @Published var sensitivity: Double = 1.35   // 觸發門檻（g）

    private let motion = CMMotionManager()
    private var lastRepTime: Date = .distantPast
    private var armed = true

    var isAvailable: Bool { motion.isDeviceMotionAvailable || motion.isAccelerometerAvailable }

    func start() {
        guard !isRunning else { return }
        repCount = 0
        armed = true
        lastRepTime = .distantPast
        isRunning = true

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 50.0
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let a = data.userAcceleration
                let r = data.rotationRate
                let accMag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                let rotMag = sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 0.08
                let value = accMag + rotMag
                DispatchQueue.main.async { self?.evaluate(value) }
            }
        } else if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 1.0 / 50.0
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let a = data.acceleration
                let mag = abs(sqrt(a.x * a.x + a.y * a.y + a.z * a.z) - 1.0)
                DispatchQueue.main.async { self?.evaluate(mag) }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        motion.stopAccelerometerUpdates()
        isRunning = false
    }

    func reset() {
        repCount = 0
    }

    private func evaluate(_ value: Double) {
        magnitude = value
        let now = Date()
        if armed, value > sensitivity, now.timeIntervalSince(lastRepTime) > 0.35 {
            repCount += 1
            lastRepTime = now
            armed = false
            CueService.shared.impact(.light)
        }
        if !armed, value < sensitivity * 0.45 {
            armed = true
        }
    }
}
