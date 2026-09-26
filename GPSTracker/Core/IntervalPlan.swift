import Foundation

enum IntervalSegmentKind: String, Codable, CaseIterable, Identifiable {
    case prepare, work, rest, cooldown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .prepare: return "預備"
        case .work: return "衝刺"
        case .rest: return "休息"
        case .cooldown: return "緩和"
        }
    }

    var systemImage: String {
        switch self {
        case .prepare: return "hourglass"
        case .work: return "bolt.fill"
        case .rest: return "pause.fill"
        case .cooldown: return "wind"
        }
    }
}

struct IntervalSegment: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: IntervalSegmentKind
    var name: String
    var seconds: Int

    init(id: UUID = UUID(), kind: IntervalSegmentKind, name: String? = nil, seconds: Int) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.seconds = seconds
    }
}

/// 自訂課表：多段任意組合，整組可重複
struct IntervalPlan: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var segments: [IntervalSegment]
    var repeatCount: Int

    var totalSeconds: Int {
        segments.reduce(0) { $0 + $1.seconds } * max(1, repeatCount)
    }

    var workSeconds: Int {
        segments.filter { $0.kind == .work }.reduce(0) { $0 + $1.seconds } * max(1, repeatCount)
    }

    var summary: String {
        "\(segments.count) 段 × \(repeatCount) 輪・\(Fmt.duration(TimeInterval(totalSeconds)))"
    }

    static let presets: [IntervalPlan] = [
        IntervalPlan(name: "Tabata",
                     segments: [IntervalSegment(kind: .prepare, seconds: 10),
                                IntervalSegment(kind: .work, seconds: 20),
                                IntervalSegment(kind: .rest, seconds: 10)],
                     repeatCount: 8),
        IntervalPlan(name: "30／15 耐力",
                     segments: [IntervalSegment(kind: .work, seconds: 30),
                                IntervalSegment(kind: .rest, seconds: 15)],
                     repeatCount: 10),
        IntervalPlan(name: "金字塔",
                     segments: [IntervalSegment(kind: .work, name: "30 秒", seconds: 30),
                                IntervalSegment(kind: .rest, seconds: 30),
                                IntervalSegment(kind: .work, name: "60 秒", seconds: 60),
                                IntervalSegment(kind: .rest, seconds: 45),
                                IntervalSegment(kind: .work, name: "90 秒", seconds: 90),
                                IntervalSegment(kind: .rest, seconds: 60),
                                IntervalSegment(kind: .work, name: "60 秒", seconds: 60),
                                IntervalSegment(kind: .rest, seconds: 45),
                                IntervalSegment(kind: .work, name: "30 秒", seconds: 30),
                                IntervalSegment(kind: .cooldown, seconds: 120)],
                     repeatCount: 1),
        IntervalPlan(name: "軍事體能循環",
                     segments: [IntervalSegment(kind: .work, name: "伏地挺身", seconds: 45),
                                IntervalSegment(kind: .rest, seconds: 20),
                                IntervalSegment(kind: .work, name: "仰臥起坐", seconds: 45),
                                IntervalSegment(kind: .rest, seconds: 20),
                                IntervalSegment(kind: .work, name: "深蹲", seconds: 45),
                                IntervalSegment(kind: .rest, seconds: 20),
                                IntervalSegment(kind: .work, name: "開合跳", seconds: 45),
                                IntervalSegment(kind: .rest, seconds: 60)],
                     repeatCount: 4)
    ]
}

/// 課表本地儲存
final class IntervalPlanStore: ObservableObject {
    static let shared = IntervalPlanStore()

    @Published private(set) var plans: [IntervalPlan] = []

    private let key = "intervalPlans"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([IntervalPlan].self, from: data),
           !decoded.isEmpty {
            plans = decoded
        } else {
            plans = IntervalPlan.presets
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(plans) {
            defaults.set(data, forKey: key)
        }
    }

    func save(_ plan: IntervalPlan) {
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = plan
        } else {
            plans.append(plan)
        }
        persist()
    }

    func delete(_ plan: IntervalPlan) {
        plans.removeAll { $0.id == plan.id }
        if plans.isEmpty { plans = IntervalPlan.presets }
        persist()
    }

    func resetToPresets() {
        plans = IntervalPlan.presets
        persist()
    }
}
