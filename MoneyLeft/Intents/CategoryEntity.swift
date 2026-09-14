import AppIntents
import SwiftData

/// 讓 Siri 可以用「餐飲」「交通」這些詞指定分類。
struct CategoryEntity: AppEntity, Identifiable {
    var id: String
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "分類")
    static var defaultQuery = CategoryEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct CategoryEntityQuery: EntityQuery, EntityStringQuery {

    @MainActor
    private func allCategories() -> [CategoryEntity] {
        let context = AppContainer.context
        let descriptor = FetchDescriptor<SpendingCategory>(sortBy: [SortDescriptor(\.sortOrder)])
        let categories = (try? context.fetch(descriptor)) ?? []
        return categories.map { CategoryEntity(id: $0.fullName, name: $0.fullName) }
    }

    func entities(for identifiers: [String]) async throws -> [CategoryEntity] {
        await MainActor.run { allCategories().filter { identifiers.contains($0.id) } }
    }

    func entities(matching string: String) async throws -> [CategoryEntity] {
        await MainActor.run { allCategories().filter { $0.name.localizedCaseInsensitiveContains(string) } }
    }

    func suggestedEntities() async throws -> [CategoryEntity] {
        await MainActor.run { allCategories() }
    }
}
