import Foundation
import HealthKit

enum SportCategory: String, CaseIterable, Identifiable, Codable {
    case endurance, ball, strength, mindBody, water, outdoor, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .endurance: return "有氧耐力"
        case .ball: return "球類"
        case .strength: return "重訓格鬥"
        case .mindBody: return "身心伸展"
        case .water: return "水上"
        case .outdoor: return "戶外"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .endurance: return "bolt.heart.fill"
        case .ball: return "basketball.fill"
        case .strength: return "dumbbell.fill"
        case .mindBody: return "figure.mind.and.body"
        case .water: return "drop.fill"
        case .outdoor: return "mountain.2.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// 這個分類寫進健康 App 時的預設型態（自訂運動用）
    var defaultActivityType: HKWorkoutActivityType {
        switch self {
        case .endurance: return .mixedCardio
        case .ball: return .play
        case .strength: return .functionalStrengthTraining
        case .mindBody: return .flexibility
        case .water: return .swimming
        case .outdoor: return .hiking
        case .other: return .other
        }
    }
}

/// 一種運動項目。MET 為常用參考值，用於熱量估算。
struct SportKind: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let icon: String
    let met: Double
    let category: SportCategory
    /// 適合用 GPS 記錄軌跡（戶外移動型）
    let tracksDistance: Bool
    /// 通常在室內進行
    let indoor: Bool
    /// 使用者自己新增的
    var isCustom: Bool = false
}

enum SportCatalog {

    /// 內建項目。只留真的會有人記錄的，其餘請用「自訂運動」自己加。
    static let builtIn: [SportKind] = [
        // 有氧耐力
        SportKind(id: "cycling", name: "自行車（戶外）", icon: "bicycle", met: 8.0, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "indoorCycling", name: "室內飛輪", icon: "bicycle.circle", met: 8.5, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "trailRunning", name: "越野跑", icon: "figure.run", met: 10.0, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "rowingMachine", name: "划船機", icon: "figure.rower", met: 7.0, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "elliptical", name: "橢圓機", icon: "figure.elliptical", met: 5.5, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "jumpRope", name: "跳繩", icon: "figure.jumprope", met: 11.0, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "hiit", name: "高強度間歇", icon: "flame.fill", met: 9.5, category: .endurance, tracksDistance: false, indoor: true),

        // 球類
        SportKind(id: "basketball", name: "籃球", icon: "basketball.fill", met: 8.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "soccer", name: "足球", icon: "soccerball", met: 9.0, category: .ball, tracksDistance: true, indoor: false),
        SportKind(id: "badminton", name: "羽球", icon: "figure.badminton", met: 7.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "tableTennis", name: "桌球", icon: "figure.table.tennis", met: 4.5, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "tennis", name: "網球", icon: "figure.tennis", met: 7.5, category: .ball, tracksDistance: false, indoor: false),
        SportKind(id: "volleyball", name: "排球", icon: "volleyball.fill", met: 6.0, category: .ball, tracksDistance: false, indoor: true),

        // 重訓格鬥
        SportKind(id: "strengthTraining", name: "重量訓練", icon: "dumbbell.fill", met: 6.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "functionalTraining", name: "功能性訓練", icon: "figure.strengthtraining.functional", met: 6.5, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "calisthenics", name: "徒手健身", icon: "figure.play", met: 5.5, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "boxing", name: "拳擊", icon: "figure.boxing", met: 9.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "martialArts", name: "武術／格鬥", icon: "figure.martial.arts", met: 8.5, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "climbing", name: "攀岩", icon: "figure.climbing", met: 8.0, category: .strength, tracksDistance: false, indoor: true),

        // 身心伸展
        SportKind(id: "yoga", name: "瑜伽", icon: "figure.yoga", met: 3.0, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "pilates", name: "皮拉提斯", icon: "figure.pilates", met: 3.5, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "stretching", name: "伸展", icon: "figure.flexibility", met: 2.5, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "dancing", name: "舞蹈", icon: "figure.dance", met: 5.0, category: .mindBody, tracksDistance: false, indoor: true),

        // 水上
        SportKind(id: "poolSwimming", name: "泳池游泳", icon: "figure.pool.swim", met: 7.0, category: .water, tracksDistance: false, indoor: true),
        SportKind(id: "openWaterSwimming", name: "開放水域游泳", icon: "figure.open.water.swim", met: 8.0, category: .water, tracksDistance: true, indoor: false),

        // 戶外
        SportKind(id: "mountainBiking", name: "登山車", icon: "bicycle", met: 10.0, category: .outdoor, tracksDistance: true, indoor: false),
        SportKind(id: "trackAndField", name: "田徑", icon: "figure.track.and.field", met: 8.0, category: .outdoor, tracksDistance: false, indoor: false),

        // 其他
        SportKind(id: "warmUp", name: "熱身", icon: "figure.step.training", met: 3.5, category: .other, tracksDistance: false, indoor: true),
        SportKind(id: "cooldown", name: "收操緩和", icon: "figure.cooldown", met: 2.5, category: .other, tracksDistance: false, indoor: true),
        SportKind(id: "other", name: "其他運動", icon: "figure.mixed.cardio", met: 6.0, category: .other, tracksDistance: false, indoor: true),

        // 僅供「走路」「負重行軍」這兩個首頁項目對應用，不出現在選擇器裡
        SportKind(id: "walkingOutdoor", name: "戶外走路", icon: "figure.walk", met: 3.5, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "ruckMarch", name: "負重行軍", icon: "backpack.fill", met: 7.0, category: .endurance, tracksDistance: true, indoor: false)
    ]

    /// 已經有專屬首頁入口，不需要在選擇器裡重複出現
    private static let hiddenIDs: Set<String> = ["walkingOutdoor", "ruckMarch"]

    /// 內建 + 使用者自訂
    static var all: [SportKind] {
        builtIn + CustomSportStore.shared.sports
    }

    /// 選擇器實際顯示的清單
    static var visible: [SportKind] {
        all.filter { !hiddenIDs.contains($0.id) }
    }

    static func find(_ id: String?) -> SportKind? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func inCategory(_ category: SportCategory) -> [SportKind] {
        visible.filter { $0.category == category }
    }

    static func search(_ text: String) -> [SportKind] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visible }
        return visible.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// 最近使用過的項目（本地記錄）
    static func recentIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: "recentSports") ?? []
    }

    static func markUsed(_ sport: SportKind) {
        var list = recentIDs().filter { $0 != sport.id }
        list.insert(sport.id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: "recentSports")
    }

    static var recent: [SportKind] {
        recentIDs().compactMap { find($0) }.filter { !hiddenIDs.contains($0.id) }
    }

    // MARK: 與健康 App 的對應

    static func healthKitType(for sport: SportKind) -> HKWorkoutActivityType {
        switch sport.id {
        case "walkingOutdoor": return .walking
        case "ruckMarch": return .hiking
        case "cycling", "mountainBiking": return .cycling
        case "indoorCycling": return .cycling
        case "trailRunning": return .running
        case "rowingMachine": return .rowing
        case "elliptical": return .elliptical
        case "jumpRope": return .jumpRope
        case "hiit": return .highIntensityIntervalTraining
        case "basketball": return .basketball
        case "soccer": return .soccer
        case "badminton": return .badminton
        case "tableTennis": return .tableTennis
        case "tennis": return .tennis
        case "volleyball": return .volleyball
        case "strengthTraining": return .traditionalStrengthTraining
        case "functionalTraining": return .functionalStrengthTraining
        case "calisthenics": return .coreTraining
        case "boxing": return .boxing
        case "martialArts": return .martialArts
        case "climbing": return .climbing
        case "yoga": return .yoga
        case "pilates": return .pilates
        case "stretching": return .flexibility
        case "dancing": return .cardioDance
        case "poolSwimming", "openWaterSwimming": return .swimming
        case "trackAndField": return .trackAndField
        case "warmUp": return .preparationAndRecovery
        case "cooldown": return .cooldown
        default: return sport.category.defaultActivityType
        }
    }

    /// 從健康 App 匯入時，把運動型態對回本 App 的項目
    static func sport(for activity: HKWorkoutActivityType) -> SportKind? {
        switch activity {
        case .cycling: return find("cycling")
        case .rowing: return find("rowingMachine")
        case .elliptical: return find("elliptical")
        case .jumpRope: return find("jumpRope")
        case .highIntensityIntervalTraining: return find("hiit")
        case .basketball: return find("basketball")
        case .soccer: return find("soccer")
        case .badminton: return find("badminton")
        case .tableTennis: return find("tableTennis")
        case .tennis: return find("tennis")
        case .volleyball: return find("volleyball")
        case .traditionalStrengthTraining: return find("strengthTraining")
        case .functionalStrengthTraining: return find("functionalTraining")
        case .coreTraining: return find("calisthenics")
        case .boxing, .kickboxing: return find("boxing")
        case .martialArts, .wrestling: return find("martialArts")
        case .climbing: return find("climbing")
        case .yoga: return find("yoga")
        case .pilates: return find("pilates")
        case .flexibility: return find("stretching")
        case .cardioDance, .socialDance, .barre: return find("dancing")
        case .swimming: return find("poolSwimming")
        case .trackAndField: return find("trackAndField")
        case .preparationAndRecovery: return find("warmUp")
        case .cooldown: return find("cooldown")
        case .mixedCardio, .other: return find("other")
        default: return nil
        }
    }
}
