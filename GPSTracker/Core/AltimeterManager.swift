import Foundation
import CoreMotion

/// 氣壓計高度變化：完全不需要 GPS，室內爬樓梯、營區斜坡都抓得到。
final class AltimeterManager: ObservableObject {
    @Published var relativeAltitude: Double = 0
    @Published var gain: Double = 0
    @Published var loss: Double = 0
    @Published var pressure: Double = 0
    @Published var isRunning = false

    private let altimeter = CMAltimeter()
    private var lastAltitude: Double?

    var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    func start() {
        guard CMAltimeter.isRelativeAltitudeAvailable(), !isRunning else { return }
        isRunning = true
        gain = 0
        loss = 0
        lastAltitude = nil
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let altitude = data.relativeAltitude.doubleValue
            let pressure = data.pressure.doubleValue
            DispatchQueue.main.async {
                guard let self else { return }
                self.relativeAltitude = altitude
                self.pressure = pressure
                if let last = self.lastAltitude {
                    let diff = altitude - last
                    // 0.6 公尺門檻，濾掉氣壓雜訊
                    if diff > 0.6 {
                        self.gain += diff
                        self.lastAltitude = altitude
                    } else if diff < -0.6 {
                        self.loss += -diff
                        self.lastAltitude = altitude
                    }
                } else {
                    self.lastAltitude = altitude
                }
            }
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        isRunning = false
    }

    func reset() {
        gain = 0
        loss = 0
        lastAltitude = nil
    }
}
