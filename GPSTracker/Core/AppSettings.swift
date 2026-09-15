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
    @Published var autoImportHealth: Bool { didSet { defaults.set(autoImportHealth, forKey: Keys.autoImportHealth) } }
    @Published var backgroundUpdates: Bool { didSet { defaults.set(backgroundUpdates, forKey: Keys.backgroundUpdates) } }
    @Published var hasSeenOnboarding: Bool { didSet { defaults.set(hasSeenOnboarding, forKey: Keys.hasSeenOnboarding) } }
    /// 語音播報間隔：0 = 關閉，>0 為公尺；負值代表以分鐘為單位（-5 = 每 5 分鐘）
    @Published var announceIntervalRaw: Double { didSet { defaults.set(announceIntervalRaw, forKey: Keys.announceIntervalRaw) } }
    @Published var announceDistance: Bool { didSet { defaults.set(announceDistance, forKey: Keys.announceDistance) } }
    @Published var announcePace: Bool { didSet { defaults.set(announcePace, forKey: Keys.announcePace) } }
    @Published var announceDuration: Bool { didSet { defaults.set(announceDuration, forKey: Keys.announceDuration) } }
    @Published var announcePacerDelta: Bool { didSet { defaults.set(announcePacerDelta, forKey: Keys.announcePacerDelta) } }
    @Published var keepScreenAwake: Bool { didSet { defaults.set(keepScreenAwake, forKey: Keys.keepScreenAwake) } }
    @Published var batterySaver: Bool { didSet { defaults.set(batterySaver, forKey: Keys.batterySaver) } }
    /// 被隱藏的模式（raw value 陣列）
    @Published var hiddenModes: [String] { didSet { defaults.set(hiddenModes, forKey: Keys.hiddenModes) } }
    /// 釘選在最上面的模式
    @Published var pinnedModes: [String] { didSet { defaults.set(pinnedModes, forKey: Keys.pinnedModes) } }
    @Published var dailyDistanceGoal: Double { didSet { defaults.set(dailyDistanceGoal, forKey: Keys.dailyDistanceGoal) } }
    @Published var lastHealthImport: Double { didSet { defaults.set(lastHealthImport, forKey: Keys.lastHealthImport) } }

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
        static let autoImportHealth = "autoImportHealth"
        static let backgroundUpdates = "backgroundUpdates"
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let announceIntervalRaw = "announceIntervalRaw"
        static let announceDistance = "announceDistance"
        static let announcePace = "announcePace"
        static let announceDuration = "announceDuration"
        static let announcePacerDelta = "announcePacerDelta"
        static let keepScreenAwake = "keepScreenAwake"
        static let batterySaver = "batterySaver"
        static let hiddenModes = "hiddenModes"
        static let pinnedModes = "pinnedModes"
        static let dailyDistanceGoal = "dailyDistanceGoal"
        static let lastHealthImport = "lastHealthImport"
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
            Keys.liveActivityEnabled: true,
            Keys.autoImportHealth: false,
            Keys.backgroundUpdates: false,
            Keys.hasSeenOnboarding: false,
            Keys.announceIntervalRaw: 1000.0,
            Keys.announceDistance: true,
            Keys.announcePace: true,
            Keys.announceDuration: false,
            Keys.announcePacerDelta: true,
            Keys.keepScreenAwake: true,
            Keys.batterySaver: true,
            Keys.dailyDistanceGoal: 5.0,
            Keys.lastHealthImport: 0.0
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
        autoImportHealth = defaults.bool(forKey: Keys.autoImportHealth)
        backgroundUpdates = defaults.bool(forKey: Keys.backgroundUpdates)
        hasSeenOnboarding = defaults.bool(forKey: Keys.hasSeenOnboarding)
        announceIntervalRaw = defaults.double(forKey: Keys.announceIntervalRaw)
        announceDistance = defaults.bool(forKey: Keys.announceDistance)
        announcePace = defaults.bool(forKey: Keys.announcePace)
        announceDuration = defaults.bool(forKey: Keys.announceDuration)
        announcePacerDelta = defaults.bool(forKey: Keys.announcePacerDelta)
        keepScreenAwake = defaults.bool(forKey: Keys.keepScreenAwake)
        batterySaver = defaults.bool(forKey: Keys.batterySaver)
        hiddenModes = defaults.stringArray(forKey: Keys.hiddenModes) ?? []
        pinnedModes = defaults.stringArray(forKey: Keys.pinnedModes) ?? []
        dailyDistanceGoal = defaults.double(forKey: Keys.dailyDistanceGoal)
        lastHealthImport = defaults.double(forKey: Keys.lastHealthImport)
    }

    func isHidden(_ type: WorkoutType) -> Bool {
        hiddenModes.contains(type.rawValue)
    }

    func isPinned(_ type: WorkoutType) -> Bool {
        pinnedModes.contains(type.rawValue)
    }

    func toggleHidden(_ type: WorkoutType) {
        if let index = hiddenModes.firstIndex(of: type.rawValue) {
            hiddenModes.remove(at: index)
        } else {
            hiddenModes.append(type.rawValue)
            pinnedModes.removeAll { $0 == type.rawValue }
        }
    }

    func togglePinned(_ type: WorkoutType) {
        if let index = pinnedModes.firstIndex(of: type.rawValue) {
            pinnedModes.remove(at: index)
        } else {
            pinnedModes.append(type.rawValue)
            hiddenModes.removeAll { $0 == type.rawValue }
        }
    }

    /// 播報間隔的顯示文字
    var announceIntervalText: String {
        if announceIntervalRaw == 0 { return "關閉" }
        if announceIntervalRaw < 0 { return "每 \(Int(-announceIntervalRaw)) 分鐘" }
        if announceIntervalRaw >= 1000 {
            let km = announceIntervalRaw / 1000
            return km == km.rounded() ? "每 \(Int(km)) 公里" : String(format: "每 %.1f 公里", km)
        }
        return "每 \(Int(announceIntervalRaw)) 公尺"
    }

    var lastHealthImportDate: Date? {
        lastHealthImport > 0 ? Date(timeIntervalSince1970: lastHealthImport) : nil
    }

    var unit: DistanceUnit {
        get { DistanceUnit(rawValue: unitRaw) ?? .metric }
        set { unitRaw = newValue.rawValue }
    }
}
