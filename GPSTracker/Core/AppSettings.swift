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
    /// 每個運動項目各自的記錄方式偏好（discipline id -> RecordingPreference raw）
    @Published var disciplinePreferences: [String: String] { didSet { defaults.set(disciplinePreferences, forKey: Keys.disciplinePreferences) } }
    /// 地圖樣式：0 標準 1 混合 2 衛星
    @Published var mapStyleIndex: Int { didSet { defaults.set(mapStyleIndex, forKey: Keys.mapStyleIndex) } }
    /// 虛擬配速員目標配速（秒/公里），0 = 關閉
    @Published var gpsTargetPace: Double { didSet { defaults.set(gpsTargetPace, forKey: Keys.gpsTargetPace) } }
    /// GPS 自動分圈距離（公尺），0 = 關閉
    @Published var gpsAutoLapDistance: Double { didSet { defaults.set(gpsAutoLapDistance, forKey: Keys.gpsAutoLapDistance) } }
    /// 背景持續記錄軌跡（需要「永遠」定位權限）
    @Published var backgroundLocation: Bool { didSet { defaults.set(backgroundLocation, forKey: Keys.backgroundLocation) } }
    /// 負重預設重量（公斤）
    @Published var ruckLoad: Double { didSet { defaults.set(ruckLoad, forKey: Keys.ruckLoad) } }
    /// 節拍器預設步頻
    @Published var metronomeBPM: Int { didSet { defaults.set(metronomeBPM, forKey: Keys.metronomeBPM) } }
    /// 進入運動畫面預設使用大字幕
    @Published var preferBigText: Bool { didSet { defaults.set(preferBigText, forKey: Keys.preferBigText) } }
    /// 自訂的目標配速清單（秒/公里），顯示在運動畫面的快捷列
    @Published var customPaces: [Double] { didSet { defaults.set(customPaces, forKey: Keys.customPaces) } }
    /// 自訂的自動分圈距離清單（公尺）
    @Published var customLapDistances: [Double] { didSet { defaults.set(customLapDistances, forKey: Keys.customLapDistances) } }

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
        static let disciplinePreferences = "disciplinePreferences"
        static let mapStyleIndex = "mapStyleIndex"
        static let gpsTargetPace = "gpsTargetPace"
        static let gpsAutoLapDistance = "gpsAutoLapDistance"
        static let backgroundLocation = "backgroundLocation"
        static let ruckLoad = "ruckLoad"
        static let metronomeBPM = "metronomeBPM"
        static let preferBigText = "preferBigText"
        static let customPaces = "customPaces"
        static let customLapDistances = "customLapDistances"
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
            Keys.lastHealthImport: 0.0,
            Keys.mapStyleIndex: 0,
            Keys.gpsTargetPace: 0.0,
            Keys.gpsAutoLapDistance: 1000.0,
            Keys.backgroundLocation: true,
            Keys.ruckLoad: 0.0,
            Keys.metronomeBPM: 170,
            Keys.preferBigText: false
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
        disciplinePreferences = defaults.dictionary(forKey: Keys.disciplinePreferences) as? [String: String] ?? [:]
        mapStyleIndex = defaults.integer(forKey: Keys.mapStyleIndex)
        gpsTargetPace = defaults.double(forKey: Keys.gpsTargetPace)
        gpsAutoLapDistance = defaults.double(forKey: Keys.gpsAutoLapDistance)
        backgroundLocation = defaults.bool(forKey: Keys.backgroundLocation)
        ruckLoad = defaults.double(forKey: Keys.ruckLoad)
        metronomeBPM = defaults.integer(forKey: Keys.metronomeBPM)
        preferBigText = defaults.bool(forKey: Keys.preferBigText)
        customPaces = (defaults.array(forKey: Keys.customPaces) as? [Double]) ?? AppSettings.defaultPaces
        customLapDistances = (defaults.array(forKey: Keys.customLapDistances) as? [Double]) ?? AppSettings.defaultLapDistances
    }

    // MARK: 自訂快捷清單

    static let defaultPaces: [Double] = [420, 390, 360, 330, 300, 270]
    static let defaultLapDistances: [Double] = [400, 500, 1000, 1609.344]

    /// 加入一組自訂配速（秒/公里），自動去重、排序、最多 8 筆
    func addCustomPace(_ secondsPerKM: Double) {
        guard secondsPerKM > 0 else { return }
        let rounded = (secondsPerKM).rounded()
        var list = customPaces.filter { abs($0 - rounded) > 0.5 }
        list.append(rounded)
        customPaces = Array(list.sorted(by: >).prefix(8))
    }

    func removeCustomPace(_ secondsPerKM: Double) {
        customPaces = customPaces.filter { abs($0 - secondsPerKM) > 0.5 }
    }

    /// 加入一組自訂分圈距離（公尺）
    func addCustomLapDistance(_ meters: Double) {
        guard meters > 0 else { return }
        let rounded = (meters * 100).rounded() / 100
        var list = customLapDistances.filter { abs($0 - rounded) > 0.5 }
        list.append(rounded)
        customLapDistances = Array(list.sorted().prefix(8))
    }

    func removeCustomLapDistance(_ meters: Double) {
        customLapDistances = customLapDistances.filter { abs($0 - meters) > 0.5 }
    }

    func resetCustomLists() {
        customPaces = AppSettings.defaultPaces
        customLapDistances = AppSettings.defaultLapDistances
    }

    // MARK: 運動項目偏好

    func preference(for disciplineID: String) -> RecordingPreference {
        RecordingPreference(rawValue: disciplinePreferences[disciplineID] ?? "") ?? .auto
    }

    func setPreference(_ preference: RecordingPreference, for disciplineID: String) {
        var copy = disciplinePreferences
        copy[disciplineID] = preference.rawValue
        disciplinePreferences = copy
    }

    // MARK: 首頁排列（以項目 id 為準）

    func isHidden(id: String) -> Bool { hiddenModes.contains(id) }
    func isPinned(id: String) -> Bool { pinnedModes.contains(id) }

    func toggleHidden(id: String) {
        if let index = hiddenModes.firstIndex(of: id) {
            hiddenModes.remove(at: index)
        } else {
            hiddenModes.append(id)
            pinnedModes.removeAll { $0 == id }
        }
    }

    func togglePinned(id: String) {
        if let index = pinnedModes.firstIndex(of: id) {
            pinnedModes.remove(at: index)
        } else {
            pinnedModes.append(id)
            hiddenModes.removeAll { $0 == id }
        }
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
