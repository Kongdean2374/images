import Foundation

struct ExerciseItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var met: Double
    var systemImage: String
    /// 建議的偵測靈敏度（g）
    var sensitivity: Double

    static let builtIn: [ExerciseItem] = [
        ExerciseItem(name: "開合跳", met: 8.0, systemImage: "figure.jumprope", sensitivity: 1.35),
        ExerciseItem(name: "波比跳", met: 9.5, systemImage: "figure.cross.training", sensitivity: 1.6),
        ExerciseItem(name: "深蹲", met: 5.5, systemImage: "figure.strengthtraining.functional", sensitivity: 1.1),
        ExerciseItem(name: "登山者", met: 8.0, systemImage: "figure.climbing", sensitivity: 1.2),
        ExerciseItem(name: "高抬腿", met: 8.5, systemImage: "figure.highintensity.intervaltraining", sensitivity: 1.3),
        ExerciseItem(name: "伏地挺身", met: 7.0, systemImage: "figure.wrestling", sensitivity: 1.0),
        ExerciseItem(name: "仰臥起坐", met: 6.0, systemImage: "figure.core.training", sensitivity: 0.95)
    ]
}

/// 動作庫（本地儲存，可自訂新增／刪除）
final class ExerciseLibrary: ObservableObject {
    static let shared = ExerciseLibrary()

    @Published private(set) var items: [ExerciseItem] = []

    private let key = "exerciseLibrary"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ExerciseItem].self, from: data),
           !decoded.isEmpty {
            items = decoded
        } else {
            items = ExerciseItem.builtIn
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }

    func add(name: String, met: Double, systemImage: String = "figure.strengthtraining.functional", sensitivity: Double = 1.2) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !items.contains(where: { $0.name == trimmed }) else { return }
        items.append(ExerciseItem(name: trimmed, met: met, systemImage: systemImage, sensitivity: sensitivity))
        persist()
    }

    func remove(_ item: ExerciseItem) {
        items.removeAll { $0.id == item.id }
        if items.isEmpty { items = ExerciseItem.builtIn }
        persist()
    }

    func resetToDefaults() {
        items = ExerciseItem.builtIn
        persist()
    }
}

/// 循環訓練設定（每組做幾下、幾組、組間休息）
struct CircuitConfig: Codable, Equatable {
    var repsPerSet: Int = 20
    var sets: Int = 3
    var restSeconds: Int = 30
    var enabled: Bool = false

    var totalReps: Int { repsPerSet * sets }
}
