import Foundation
import SwiftUI

/// 進入運動項目後要用哪一種記錄方式。
enum RecordingPreference: String, CaseIterable, Identifiable, Codable {
    /// 依目前定位權限自動決定
    case auto
    /// 固定使用 GPS 軌跡版
    case gps
    /// 固定使用免定位版
    case indoor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自動判斷"
        case .gps: return "GPS 軌跡版"
        case .indoor: return "免定位版"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .gps: return "location.fill"
        case .indoor: return "location.slash"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "有定位權限就用 GPS，沒有就自動換成計步版"
        case .gps: return "一律用地圖軌跡記錄（需要定位權限）"
        case .indoor: return "一律用計步／計時記錄，完全不需要定位"
        }
    }
}

/// 一個「運動項目」＝把同一種運動的 GPS 版與免定位版合併成單一入口。
struct Discipline: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let subtitle: String
    /// 有定位時使用的記錄型態
    let gpsType: WorkoutType?
    /// 無定位時使用的記錄型態
    let indoorType: WorkoutType?
    /// GPS 版對應的運動種類（nil 代表用 WorkoutType 內建語意）
    let gpsSportID: String?
    /// 免定位版對應的運動種類
    let indoorSportID: String?

    var supportsGPS: Bool { gpsType != nil }
    var supportsIndoor: Bool { indoorType != nil }
    /// 兩種版本都有 → 需要自動判斷與模式切換
    var isDual: Bool { gpsType != nil && indoorType != nil }

    var gpsSport: SportKind? { SportCatalog.find(gpsSportID) }
    var indoorSport: SportKind? { SportCatalog.find(indoorSportID) }

    /// 用來取色的代表型態
    var colorType: WorkoutType { gpsType ?? indoorType ?? .manualEntry }
}

enum DisciplineCatalog {

    static let all: [Discipline] = [
        Discipline(id: "running", name: "跑步", icon: "figure.run",
                   subtitle: "戶外軌跡・跑步機・步幅換算",
                   gpsType: .gpsRun, indoorType: .run,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "hiking", name: "健行登山", icon: "figure.hiking",
                   subtitle: "海拔爬升・免定位計步",
                   gpsType: .gpsHike, indoorType: .walk,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "walking", name: "走路", icon: "figure.walk",
                   subtitle: "散步通勤・步頻樓層",
                   gpsType: .gpsActivity, indoorType: .walk,
                   gpsSportID: "walkingOutdoor", indoorSportID: nil),

        Discipline(id: "rucking", name: "負重行軍", icon: "backpack.fill",
                   subtitle: "負重計入熱量・軍事體能",
                   gpsType: .gpsActivity, indoorType: .ruck,
                   gpsSportID: "ruckMarch", indoorSportID: nil),

        Discipline(id: "cycling", name: "自行車", icon: "bicycle",
                   subtitle: "戶外騎乘・室內飛輪",
                   gpsType: .gpsActivity, indoorType: .timedActivity,
                   gpsSportID: "cycling", indoorSportID: "indoorCycling"),

        Discipline(id: "swimming", name: "游泳", icon: "figure.pool.swim",
                   subtitle: "開放水域・泳池計時",
                   gpsType: .gpsActivity, indoorType: .timedActivity,
                   gpsSportID: "openWaterSwimming", indoorSportID: "poolSwimming"),

        Discipline(id: "stairs", name: "爬樓梯", icon: "figure.stairs",
                   subtitle: "樓層與垂直爬升",
                   gpsType: nil, indoorType: .stairs,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "lapCounter", name: "操場計圈", icon: "repeat.circle.fill",
                   subtitle: "固定圈距計圈・分圈配速",
                   gpsType: nil, indoorType: .lapCounter,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "shuttleRun", name: "折返跑", icon: "arrow.left.arrow.right",
                   subtitle: "碰線計趟・短距衝刺",
                   gpsType: nil, indoorType: .shuttleRun,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "interval", name: "間歇課表", icon: "timer",
                   subtitle: "自訂課表・語音提示",
                   gpsType: nil, indoorType: .indoorInterval,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "reps", name: "徒手訓練", icon: "figure.strengthtraining.functional",
                   subtitle: "自動計次・循環組",
                   gpsType: nil, indoorType: .indoorReps,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "plank", name: "棒式核心", icon: "figure.core.training",
                   subtitle: "撐體計時・穩定度偵測",
                   gpsType: nil, indoorType: .plank,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "fitnessTest", name: "體能測驗", icon: "checklist",
                   subtitle: "四項測驗自動評等",
                   gpsType: nil, indoorType: .fitnessTest,
                   gpsSportID: nil, indoorSportID: nil),

        Discipline(id: "manual", name: "手動補登", icon: "square.and.pencil",
                   subtitle: "事後補記任何一場訓練",
                   gpsType: nil, indoorType: .manualEntry,
                   gpsSportID: nil, indoorSportID: nil)
    ]

    /// 首頁預設順序中，需要定位的排前面
    static var dualOrGPS: [Discipline] { all.filter { $0.supportsGPS } }
    static var indoorOnly: [Discipline] { all.filter { !$0.supportsGPS } }

    static func find(_ id: String?) -> Discipline? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// 從運動目錄的項目反查是否有專屬的合併入口
    static func discipline(forSportID sportID: String) -> Discipline? {
        all.first { $0.gpsSportID == sportID || $0.indoorSportID == sportID }
    }

    /// 依偏好與目前定位權限，解析出實際要用的版本
    static func resolve(_ discipline: Discipline,
                        preference: RecordingPreference,
                        locationAvailable: Bool) -> Bool {
        guard discipline.isDual else { return discipline.supportsGPS }
        switch preference {
        case .indoor: return false
        case .gps: return locationAvailable      // 沒定位時仍自動退回免定位版
        case .auto: return locationAvailable
        }
    }
}
