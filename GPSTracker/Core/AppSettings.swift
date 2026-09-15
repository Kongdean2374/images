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
    @Published var healthKitEnabled: Bool { didSet { defaults.set(healthKitEnabled, forKey: Keys.healthKitEnabled) } }
    @Published var readHeartRate: Bool { didSet { defaults.set(readHeartRate, forKey: Keys.readHeartRate) } }
    @Published var dailyStepGoal: Int { didSet { defaults.set(dailyStepGoal, forKey: Keys.dailyStepGoal) } }
    @Published var stepReminderEnabled: Bool { didSet { defaults.set(stepReminderEnabled, forKey: Keys.stepReminderEnabled) } }
    @Published var stepReminderHour: Int { didSet { defaults.set(stepReminderHour, forKey: Keys.stepReminderHour) } }
    @Published var streakReminderEnabled: Bool { didSet { defaults.set(streakReminderEnabled, forKey: Keys.streakReminderEnabled) } }
    @Published var sedentaryReminderHours: Int { didSet { defaults.set(sedentaryReminderHours, forKey: Keys.sedentaryReminderHours) } }
    @Published var liveActivityEnabled: Bool { didSet { defaults.set(liveActivityEnabled, forKey: Keys.liveActivityEnabled) } }

    private enum Keys {
        static let unit = "unit"
        static let bodyWeight = "bodyWeight"
        static let lapDistance = "lapDistance"
        static let voiceCues = "voiceCues"
        static let hapticCues = "hapticCues"
        static let autoPause = "autoPause"
        static let mapPitch = "mapPitch"
        static let preferDarkMode = "preferDarkMode"
        static let healthKitEnabled = "healthKitEnabled"
        static let readHeartRate = "readHeartRate"
        static let dailyStepGoal = "dailyStepGoal"
        static let stepReminderEnabled = "stepReminderEnabled"
        static let stepReminderHour = "stepReminderHour"
        static let streakReminderEnabled = "streakReminderEnabled"
        static let sedentaryReminderHours = "sedentaryReminderHours"
        static let liveActivityEnabled = "liveActivityEnabled"
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
            Keys.preferDarkMode: true,
            Keys.healthKitEnabled: false,
            Keys.readHeartRate: false,
            Keys.dailyStepGoal: 8000,
            Keys.stepReminderEnabled: false,
            Keys.stepReminderHour: 20,
            Keys.streakReminderEnabled: false,
            Keys.sedentaryReminderHours: 0,
            Keys.liveActivityEnabled: true
        ])
        unitRaw = defaults.string(forKey: Keys.unit) ?? DistanceUnit.metric.rawValue
        bodyWeight = defaults.double(forKey: Keys.bodyWeight)
        lapDistance = defaults.double(forKey: Keys.lapDistance)
        voiceCues = defaults.bool(forKey: Keys.voiceCues)
        hapticCues = defaults.bool(forKey: Keys.hapticCues)
        autoPause = defaults.bool(forKey: Keys.autoPause)
        mapPitch = defaults.double(forKey: Keys.mapPitch)
        preferDarkMode = defaults.bool(forKey: Keys.preferDarkMode)
        healthKitEnabled = defaults.bool(forKey: Keys.healthKitEnabled)
        readHeartRate = defaults.bool(forKey: Keys.readHeartRate)
        dailyStepGoal = defaults.integer(forKey: Keys.dailyStepGoal)
        stepReminderEnabled = defaults.bool(forKey: Keys.stepReminderEnabled)
        stepReminderHour = defaults.integer(forKey: Keys.stepReminderHour)
        streakReminderEnabled = defaults.bool(forKey: Keys.streakReminderEnabled)
        sedentaryReminderHours = defaults.integer(forKey: Keys.sedentaryReminderHours)
        liveActivityEnabled = defaults.bool(forKey: Keys.liveActivityEnabled)
    }

    var unit: DistanceUnit {
        get { DistanceUnit(rawValue: unitRaw) ?? .metric }
        set { unitRaw = newValue.rawValue }
    }
}
