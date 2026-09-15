import Foundation

/// 無定位模式也能設定的訓練目標
enum WorkoutTarget: Equatable, Hashable {
    case none
    case distance(Double)     // 公尺
    case steps(Int)
    case duration(TimeInterval)
    case calories(Double)
    case floors(Int)

    var isActive: Bool { self != .none }

    var displayName: String {
        switch self {
        case .none: return "自由訓練"
        case .distance: return "目標距離"
        case .steps: return "目標步數"
        case .duration: return "目標時間"
        case .calories: return "目標熱量"
        case .floors: return "目標樓層"
        }
    }

    func targetText(unit: DistanceUnit) -> String {
        switch self {
        case .none: return "--"
        case .distance(let value): return Fmt.distance(value, unit: unit)
        case .steps(let value): return "\(value) 步"
        case .duration(let value): return Fmt.duration(value)
        case .calories(let value): return String(format: "%.0f kcal", value)
        case .floors(let value): return "\(value) 層"
        }
    }

    func progress(distance: Double, steps: Int, duration: TimeInterval, calories: Double, floors: Int = 0) -> Double {
        switch self {
        case .none: return 0
        case .distance(let value): return value > 0 ? min(1, distance / value) : 0
        case .steps(let value): return value > 0 ? min(1, Double(steps) / Double(value)) : 0
        case .duration(let value): return value > 0 ? min(1, duration / value) : 0
        case .calories(let value): return value > 0 ? min(1, calories / value) : 0
        case .floors(let value): return value > 0 ? min(1, Double(floors) / Double(value)) : 0
        }
    }

    func remainingText(distance: Double, steps: Int, duration: TimeInterval, calories: Double, floors: Int = 0, unit: DistanceUnit) -> String {
        switch self {
        case .none: return ""
        case .distance(let value): return "還差 \(Fmt.distance(max(0, value - distance), unit: unit))"
        case .steps(let value): return "還差 \(max(0, value - steps)) 步"
        case .duration(let value): return "還差 \(Fmt.duration(max(0, value - duration)))"
        case .calories(let value): return String(format: "還差 %.0f kcal", max(0, value - calories))
        case .floors(let value): return "還差 \(max(0, value - floors)) 層"
        }
    }
}
