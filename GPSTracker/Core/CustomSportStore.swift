import Foundation
import Combine

/// 使用者自己新增的運動項目。內建清單只留常見的，其餘自己加，
/// 這樣選擇器不會被一堆用不到的項目灌水。
final class CustomSportStore: ObservableObject {
    static let shared = CustomSportStore()

    @Published private(set) var sports: [SportKind] = []

    private let key = "customSports"

    private init() {
        load()
    }

    /// 可選的圖示（涵蓋大部分運動，不用打字）
    static let iconChoices: [String] = [
        "figure.mixed.cardio", "figure.run", "figure.walk", "bicycle",
        "dumbbell.fill", "figure.strengthtraining.traditional", "figure.core.training",
        "basketball.fill", "soccerball", "volleyball.fill", "tennis.racket",
        "figure.pool.swim", "drop.fill", "sailboat.fill", "snowflake",
        "figure.yoga", "figure.flexibility", "figure.dance", "figure.boxing",
        "figure.climbing", "figure.skiing.downhill", "figure.skating",
        "mountain.2.fill", "tent.fill", "hammer.fill", "leaf.fill",
        "flame.fill", "bolt.heart.fill", "heart.fill", "star.fill"
    ]

    /// 強度級距 → MET，避免要使用者自己查 MET 表
    enum Intensity: String, CaseIterable, Identifiable, Codable {
        case easy, moderate, hard, veryHard

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .easy: return "輕鬆"
            case .moderate: return "中等"
            case .hard: return "激烈"
            case .veryHard: return "非常激烈"
            }
        }

        var detail: String {
            switch self {
            case .easy: return "還能正常聊天，例如伸展、散步式的活動"
            case .moderate: return "會喘但講得出完整句子，多數球類與重訓"
            case .hard: return "只講得出短句，會流不少汗"
            case .veryHard: return "講不出話，接近全力"
            }
        }

        var met: Double {
            switch self {
            case .easy: return 3.0
            case .moderate: return 6.0
            case .hard: return 8.5
            case .veryHard: return 11.0
            }
        }

        static func closest(to met: Double) -> Intensity {
            allCases.min { abs($0.met - met) < abs($1.met - met) } ?? .moderate
        }
    }

    // MARK: 增刪改

    func add(name: String,
             icon: String,
             category: SportCategory,
             intensity: Intensity,
             tracksDistance: Bool) -> SportKind {
        let sport = SportKind(id: "custom-\(UUID().uuidString)",
                              name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              icon: icon,
                              met: intensity.met,
                              category: category,
                              tracksDistance: tracksDistance,
                              indoor: !tracksDistance,
                              isCustom: true)
        sports.append(sport)
        save()
        return sport
    }

    func update(_ sport: SportKind,
                name: String,
                icon: String,
                category: SportCategory,
                intensity: Intensity,
                tracksDistance: Bool) {
        guard let index = sports.firstIndex(where: { $0.id == sport.id }) else { return }
        sports[index] = SportKind(id: sport.id,
                                  name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  icon: icon,
                                  met: intensity.met,
                                  category: category,
                                  tracksDistance: tracksDistance,
                                  indoor: !tracksDistance,
                                  isCustom: true)
        save()
    }

    func remove(_ sport: SportKind) {
        sports.removeAll { $0.id == sport.id }
        save()
    }

    // MARK: 儲存

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SportKind].self, from: data) else { return }
        sports = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sports) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
