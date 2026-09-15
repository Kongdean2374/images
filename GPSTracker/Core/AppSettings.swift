import Foundation
import SwiftUI

/// 使用者偏好（純本地儲存，不連後端）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var unitRaw: String { didSet { defaults.set(unitRaw, forKey: Keys.unit) } }
    @Published var bodyWeight: Double { didSet { defaults.set(bodyWeight, forKey: Keys.bodyWeight) } }
    @Published var lapDistance: Double { didSet { defaults.set(lapDistance, forKey: Keys.lapDistance) } }
    @Published var voiceCues: Bool { didSet { defaults.set(voiceCues, forKey: Keys.voiceCues) } }
    @Published var hapticCues: Bool { didSet { defaults.set(hapticCues, forKey: Keys.hapticCues) } }
    @Published var autoPause: Bool { didSet { defaults.set(autoPause, forKey: Keys.autoPause) } }
    @Published var mapPitch: Double { didSet { defaults.set(mapPitch, forKey: Keys.mapPitch) } }
    @Published var preferDarkMode: Bool { didSet { defaults.set(preferDarkMode, forKey: Keys.preferDarkMode) } }

    private enum Keys {
        static let unit = "unit"
        static let bodyWeight = "bodyWeight"
        static let lapDistance = "lapDistance"
        static let voiceCues = "voiceCues"
        static let hapticCues = "hapticCues"
        static let autoPause = "autoPause"
        static let mapPitch = "mapPitch"
        static let preferDarkMode = "preferDarkMode"
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.unit: DistanceUnit.metric.rawValue,
            Keys.bodyWeight: 65.0,
            Keys.lapDistance: 400.0,
            Keys.voiceCues: true,
            Keys.hapticCues: true,
            Keys.autoPause: true,
            Keys.mapPitch: 55.0,
            Keys.preferDarkMode: true
        ])
        unitRaw = defaults.string(forKey: Keys.unit) ?? DistanceUnit.metric.rawValue
        bodyWeight = defaults.double(forKey: Keys.bodyWeight)
        lapDistance = defaults.double(forKey: Keys.lapDistance)
        voiceCues = defaults.bool(forKey: Keys.voiceCues)
        hapticCues = defaults.bool(forKey: Keys.hapticCues)
        autoPause = defaults.bool(forKey: Keys.autoPause)
        mapPitch = defaults.double(forKey: Keys.mapPitch)
        preferDarkMode = defaults.bool(forKey: Keys.preferDarkMode)
    }

    var unit: DistanceUnit {
        get { DistanceUnit(rawValue: unitRaw) ?? .metric }
        set { unitRaw = newValue.rawValue }
    }
}
