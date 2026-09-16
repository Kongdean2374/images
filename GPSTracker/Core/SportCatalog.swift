import Foundation
import HealthKit

enum SportCategory: String, CaseIterable, Identifiable, Codable {
    case endurance, ball, strength, mindBody, water, snow, outdoor, daily, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .endurance: return "有氧耐力"
        case .ball: return "球類"
        case .strength: return "重訓體能"
        case .mindBody: return "身心伸展"
        case .water: return "水上"
        case .snow: return "冰雪"
        case .outdoor: return "戶外"
        case .daily: return "日常"
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
        case .snow: return "snowflake"
        case .outdoor: return "mountain.2.fill"
        case .daily: return "house.fill"
        case .other: return "ellipsis.circle.fill"
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
}

enum SportCatalog {

    static let all: [SportKind] = [
        // 有氧耐力
        SportKind(id: "walkingOutdoor", name: "戶外走路", icon: "figure.walk", met: 3.5, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "ruckMarch", name: "負重行軍", icon: "backpack.fill", met: 7.0, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "nordicWalking", name: "北歐式健走", icon: "figure.walk.motion", met: 5.5, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "cycling", name: "自行車（戶外）", icon: "bicycle", met: 8.0, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "indoorCycling", name: "室內飛輪", icon: "bicycle.circle", met: 8.5, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "trailRunning", name: "越野跑", icon: "figure.run", met: 10.0, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "rowingMachine", name: "划船機", icon: "figure.rower", met: 7.0, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "elliptical", name: "橢圓機", icon: "figure.elliptical", met: 5.5, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "stairMachine", name: "階梯機", icon: "figure.stair.stepper", met: 9.0, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "jumpRope", name: "跳繩", icon: "figure.jumprope", met: 11.0, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "hiit", name: "高強度間歇", icon: "flame.fill", met: 9.5, category: .endurance, tracksDistance: false, indoor: true),
        SportKind(id: "handCycling", name: "手搖車", icon: "figure.hand.cycling", met: 6.0, category: .endurance, tracksDistance: true, indoor: false),
        SportKind(id: "wheelchair", name: "輪椅推行", icon: "figure.roll", met: 6.5, category: .endurance, tracksDistance: true, indoor: false),

        // 球類
        SportKind(id: "basketball", name: "籃球", icon: "basketball.fill", met: 8.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "soccer", name: "足球", icon: "soccerball", met: 9.0, category: .ball, tracksDistance: true, indoor: false),
        SportKind(id: "volleyball", name: "排球", icon: "volleyball.fill", met: 6.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "badminton", name: "羽球", icon: "figure.badminton", met: 7.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "tableTennis", name: "桌球", icon: "figure.table.tennis", met: 4.5, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "tennis", name: "網球", icon: "figure.tennis", met: 7.5, category: .ball, tracksDistance: false, indoor: false),
        SportKind(id: "baseball", name: "棒壘球", icon: "figure.baseball", met: 5.0, category: .ball, tracksDistance: false, indoor: false),
        SportKind(id: "golf", name: "高爾夫", icon: "figure.golf", met: 4.8, category: .ball, tracksDistance: true, indoor: false),
        SportKind(id: "bowling", name: "保齡球", icon: "figure.bowling", met: 3.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "squash", name: "壁球", icon: "figure.squash", met: 10.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "pickleball", name: "匹克球", icon: "figure.pickleball", met: 6.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "handball", name: "手球", icon: "figure.handball", met: 8.0, category: .ball, tracksDistance: false, indoor: true),
        SportKind(id: "rugby", name: "橄欖球", icon: "figure.rugby", met: 8.3, category: .ball, tracksDistance: true, indoor: false),
        SportKind(id: "hockey", name: "曲棍球", icon: "figure.hockey", met: 8.0, category: .ball, tracksDistance: false, indoor: false),

        // 重訓體能
        SportKind(id: "strengthTraining", name: "重量訓練", icon: "dumbbell.fill", met: 6.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "functionalTraining", name: "功能性訓練", icon: "figure.strengthtraining.functional", met: 6.5, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "coreTraining", name: "核心訓練", icon: "figure.core.training", met: 5.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "calisthenics", name: "徒手健身", icon: "figure.play", met: 6.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "crossTraining", name: "綜合訓練", icon: "figure.cross.training", met: 7.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "boxing", name: "拳擊", icon: "figure.boxing", met: 9.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "kickboxing", name: "踢拳", icon: "figure.kickboxing", met: 9.5, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "martialArts", name: "武術／格鬥", icon: "figure.martial.arts", met: 9.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "climbing", name: "攀岩", icon: "figure.climbing", met: 8.0, category: .strength, tracksDistance: false, indoor: true),
        SportKind(id: "wrestling", name: "角力／柔道", icon: "figure.wrestling", met: 8.5, category: .strength, tracksDistance: false, indoor: true),

        // 身心伸展
        SportKind(id: "yoga", name: "瑜伽", icon: "figure.yoga", met: 3.0, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "pilates", name: "皮拉提斯", icon: "figure.pilates", met: 3.5, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "stretching", name: "伸展", icon: "figure.flexibility", met: 2.5, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "taiChi", name: "太極", icon: "figure.taichi", met: 3.0, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "barre", name: "芭蕾提斯", icon: "figure.barre", met: 4.0, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "breathing", name: "呼吸練習", icon: "wind", met: 1.5, category: .mindBody, tracksDistance: false, indoor: true),
        SportKind(id: "dancing", name: "舞蹈", icon: "figure.dance", met: 6.0, category: .mindBody, tracksDistance: false, indoor: true),

        // 水上
        SportKind(id: "poolSwimming", name: "泳池游泳", icon: "figure.pool.swim", met: 7.0, category: .water, tracksDistance: false, indoor: true),
        SportKind(id: "openWaterSwimming", name: "開放水域游泳", icon: "figure.open.water.swim", met: 8.0, category: .water, tracksDistance: true, indoor: false),
        SportKind(id: "kayaking", name: "獨木舟", icon: "figure.outdoor.rowing", met: 5.0, category: .water, tracksDistance: true, indoor: false),
        SportKind(id: "paddleboard", name: "立式划槳", icon: "figure.surfing", met: 6.0, category: .water, tracksDistance: true, indoor: false),
        SportKind(id: "surfing", name: "衝浪", icon: "figure.surfing", met: 5.0, category: .water, tracksDistance: false, indoor: false),
        SportKind(id: "waterFitness", name: "水中有氧", icon: "figure.water.fitness", met: 5.5, category: .water, tracksDistance: false, indoor: true),
        SportKind(id: "sailing", name: "帆船", icon: "sailboat.fill", met: 3.5, category: .water, tracksDistance: true, indoor: false),
        SportKind(id: "fishing", name: "釣魚", icon: "fish.fill", met: 3.0, category: .water, tracksDistance: false, indoor: false),

        // 冰雪
        SportKind(id: "downhillSkiing", name: "滑雪（下坡）", icon: "figure.skiing.downhill", met: 7.0, category: .snow, tracksDistance: true, indoor: false),
        SportKind(id: "crossCountrySkiing", name: "越野滑雪", icon: "figure.skiing.crosscountry", met: 9.0, category: .snow, tracksDistance: true, indoor: false),
        SportKind(id: "snowboarding", name: "單板滑雪", icon: "figure.snowboarding", met: 6.5, category: .snow, tracksDistance: true, indoor: false),
        SportKind(id: "iceSkating", name: "溜冰", icon: "figure.ice.skating", met: 6.0, category: .snow, tracksDistance: false, indoor: true),

        // 戶外
        SportKind(id: "mountainBiking", name: "登山車", icon: "bicycle", met: 10.0, category: .outdoor, tracksDistance: true, indoor: false),
        SportKind(id: "skateboarding", name: "滑板", icon: "figure.skating", met: 5.0, category: .outdoor, tracksDistance: true, indoor: false),
        SportKind(id: "equestrian", name: "騎馬", icon: "figure.equestrian.sports", met: 5.5, category: .outdoor, tracksDistance: true, indoor: false),
        SportKind(id: "archery", name: "射箭", icon: "target", met: 3.5, category: .outdoor, tracksDistance: false, indoor: false),
        SportKind(id: "hunting", name: "打獵／野外行進", icon: "binoculars.fill", met: 5.0, category: .outdoor, tracksDistance: true, indoor: false),
        SportKind(id: "trackAndField", name: "田徑", icon: "figure.track.and.field", met: 8.0, category: .outdoor, tracksDistance: false, indoor: false),

        // 日常
        SportKind(id: "housework", name: "家務勞動", icon: "house.fill", met: 3.3, category: .daily, tracksDistance: false, indoor: true),
        SportKind(id: "gardening", name: "園藝農作", icon: "leaf.fill", met: 4.0, category: .daily, tracksDistance: false, indoor: false),
        SportKind(id: "manualLabour", name: "體力勤務", icon: "hammer.fill", met: 5.5, category: .daily, tracksDistance: false, indoor: false),
        SportKind(id: "playWithKids", name: "陪小孩玩", icon: "figure.and.child.holdinghands", met: 4.0, category: .daily, tracksDistance: false, indoor: false),

        // 其他
        SportKind(id: "cooldown", name: "收操緩和", icon: "figure.cooldown", met: 2.5, category: .other, tracksDistance: false, indoor: true),
        SportKind(id: "warmUp", name: "熱身", icon: "figure.step.training", met: 3.5, category: .other, tracksDistance: false, indoor: true),
        SportKind(id: "other", name: "其他運動", icon: "figure.mixed.cardio", met: 6.0, category: .other, tracksDistance: false, indoor: true)
    ]

    static func find(_ id: String?) -> SportKind? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func inCategory(_ category: SportCategory) -> [SportKind] {
        all.filter { $0.category == category }
    }

    static func search(_ text: String) -> [SportKind] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
        recentIDs().compactMap { find($0) }
    }

    // MARK: 與健康 App 的對應

    static func healthKitType(for sport: SportKind) -> HKWorkoutActivityType {
        switch sport.id {
        case "walkingOutdoor", "nordicWalking": return .walking
        case "ruckMarch": return .hiking
        case "cycling", "mountainBiking": return .cycling
        case "indoorCycling": return .cycling
        case "trailRunning": return .running
        case "rowingMachine": return .rowing
        case "elliptical": return .elliptical
        case "stairMachine": return .stairClimbing
        case "jumpRope": return .jumpRope
        case "hiit": return .highIntensityIntervalTraining
        case "handCycling": return .handCycling
        case "wheelchair": return .wheelchairRunPace
        case "basketball": return .basketball
        case "soccer": return .soccer
        case "volleyball": return .volleyball
        case "badminton": return .badminton
        case "tableTennis": return .tableTennis
        case "tennis": return .tennis
        case "baseball": return .baseball
        case "golf": return .golf
        case "bowling": return .bowling
        case "squash": return .squash
        case "pickleball": return .pickleball
        case "handball": return .handball
        case "rugby": return .rugby
        case "hockey": return .hockey
        case "strengthTraining": return .traditionalStrengthTraining
        case "functionalTraining": return .functionalStrengthTraining
        case "coreTraining": return .coreTraining
        case "calisthenics": return .functionalStrengthTraining
        case "crossTraining": return .crossTraining
        case "boxing": return .boxing
        case "kickboxing": return .kickboxing
        case "martialArts": return .martialArts
        case "climbing": return .climbing
        case "wrestling": return .wrestling
        case "yoga": return .yoga
        case "pilates": return .pilates
        case "stretching": return .flexibility
        case "taiChi": return .taiChi
        case "barre": return .barre
        case "breathing": return .mindAndBody
        case "dancing": return .cardioDance
        case "poolSwimming", "openWaterSwimming": return .swimming
        case "kayaking": return .paddleSports
        case "paddleboard": return .paddleSports
        case "surfing": return .surfingSports
        case "waterFitness": return .waterFitness
        case "sailing": return .sailing
        case "fishing": return .fishing
        case "downhillSkiing": return .downhillSkiing
        case "crossCountrySkiing": return .crossCountrySkiing
        case "snowboarding": return .snowboarding
        case "iceSkating": return .skatingSports
        case "skateboarding": return .skatingSports
        case "equestrian": return .equestrianSports
        case "archery": return .archery
        case "hunting": return .hunting
        case "trackAndField": return .trackAndField
        case "housework", "gardening": return .other
        case "manualLabour": return .other
        case "playWithKids": return .play
        case "cooldown": return .cooldown
        case "warmUp": return .preparationAndRecovery
        default: return .other
        }
    }

    /// 健康 App 匯入時反查項目
    static func sport(for activity: HKWorkoutActivityType) -> SportKind? {
        switch activity {
        case .cycling: return find("cycling")
        case .rowing: return find("rowingMachine")
        case .elliptical: return find("elliptical")
        case .jumpRope: return find("jumpRope")
        case .handCycling: return find("handCycling")
        case .basketball: return find("basketball")
        case .soccer: return find("soccer")
        case .volleyball: return find("volleyball")
        case .badminton: return find("badminton")
        case .tableTennis: return find("tableTennis")
        case .tennis: return find("tennis")
        case .baseball, .softball: return find("baseball")
        case .golf: return find("golf")
        case .bowling: return find("bowling")
        case .squash: return find("squash")
        case .pickleball: return find("pickleball")
        case .handball: return find("handball")
        case .rugby: return find("rugby")
        case .hockey: return find("hockey")
        case .traditionalStrengthTraining: return find("strengthTraining")
        case .functionalStrengthTraining: return find("functionalTraining")
        case .coreTraining: return find("coreTraining")
        case .crossTraining: return find("crossTraining")
        case .boxing: return find("boxing")
        case .kickboxing: return find("kickboxing")
        case .martialArts: return find("martialArts")
        case .climbing: return find("climbing")
        case .wrestling: return find("wrestling")
        case .yoga: return find("yoga")
        case .pilates: return find("pilates")
        case .flexibility: return find("stretching")
        case .taiChi: return find("taiChi")
        case .barre: return find("barre")
        case .mindAndBody: return find("breathing")
        case .cardioDance, .socialDance: return find("dancing")
        case .swimming: return find("poolSwimming")
        case .paddleSports: return find("kayaking")
        case .surfingSports: return find("surfing")
        case .waterFitness: return find("waterFitness")
        case .sailing: return find("sailing")
        case .fishing: return find("fishing")
        case .downhillSkiing: return find("downhillSkiing")
        case .crossCountrySkiing: return find("crossCountrySkiing")
        case .snowboarding: return find("snowboarding")
        case .skatingSports: return find("iceSkating")
        case .equestrianSports: return find("equestrian")
        case .archery: return find("archery")
        case .hunting: return find("hunting")
        case .trackAndField: return find("trackAndField")
        case .play: return find("playWithKids")
        case .cooldown: return find("cooldown")
        case .preparationAndRecovery: return find("warmUp")
        case .stairClimbing: return find("stairMachine")
        case .highIntensityIntervalTraining: return find("hiit")
        default: return nil
        }
    }
}
