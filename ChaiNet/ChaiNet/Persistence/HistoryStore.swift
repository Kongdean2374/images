import Foundation
import SwiftData
import ChaiNetCore

/// Local history. Protocol so view models can be tested with an in-memory store.
@MainActor
protocol HistoryStoring: AnyObject {
    func save(_ result: TestResult) throws
    func allResults() -> [TestResult]
    func results(limit: Int?) -> [TestResult]
    func delete(ids: Set<UUID>) throws
    func deleteAll() throws
    func applyRetention(days: Int?) throws
    func saveSession(_ session: DiagnosticSession, analysis: RootCauseAnalysis?) throws
    func sessions() -> [DiagnosticSession]
    func deleteSession(id: UUID) throws
    var changeToken: Int { get }
}

@MainActor
@Observable
final class SwiftDataHistoryStore: HistoryStoring {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    /// Bumped on every write so SwiftUI views can refresh.
    private(set) var changeToken = 0

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: StoredResult.self, StoredSession.self, configurations: config)
    }

    func save(_ result: TestResult) throws {
        let data = try Codec.encoder().encode(result)
        let id = result.id
        let existing = try context.fetch(FetchDescriptor<StoredResult>(predicate: #Predicate { $0.id == id }))
        existing.forEach { context.delete($0) }
        context.insert(StoredResult(result: result, payload: data))
        try context.save()
        changeToken += 1
    }

    func allResults() -> [TestResult] { results(limit: nil) }

    func results(limit: Int?) -> [TestResult] {
        var descriptor = FetchDescriptor<StoredResult>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        if let limit { descriptor.fetchLimit = limit }
        let stored = (try? context.fetch(descriptor)) ?? []
        let decoder = Codec.decoder()
        return stored.compactMap { try? decoder.decode(TestResult.self, from: $0.payload) }
    }

    func delete(ids: Set<UUID>) throws {
        let all = try context.fetch(FetchDescriptor<StoredResult>())
        for r in all where ids.contains(r.id) { context.delete(r) }
        try context.save()
        changeToken += 1
    }

    func deleteAll() throws {
        try context.delete(model: StoredResult.self)
        try context.delete(model: StoredSession.self)
        try context.save()
        changeToken += 1
    }

    func applyRetention(days: Int?) throws {
        guard let days else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = try context.fetch(FetchDescriptor<StoredResult>(predicate: #Predicate { $0.date < cutoff }))
        guard !old.isEmpty else { return }
        old.forEach { context.delete($0) }
        try context.save()
        changeToken += 1
    }

    func saveSession(_ session: DiagnosticSession, analysis: RootCauseAnalysis?) throws {
        let data = try Codec.encoder().encode(session)
        let id = session.id
        let stored: StoredSession
        if let existing = try context.fetch(FetchDescriptor<StoredSession>(predicate: #Predicate { $0.id == id })).first {
            stored = existing
            stored.payload = data
        } else {
            stored = StoredSession(id: session.id, title: session.title, createdAt: session.createdAt, payload: data)
            context.insert(stored)
        }
        stored.title = session.title
        stored.updatedAt = Date()
        stored.testCount = session.tests.count
        stored.topCause = analysis?.mostLikely?.title
        stored.topConfidence = analysis?.mostLikely?.confidencePercent
        try context.save()
        changeToken += 1
    }

    func sessions() -> [DiagnosticSession] {
        let stored = (try? context.fetch(FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let decoder = Codec.decoder()
        return stored.compactMap { try? decoder.decode(DiagnosticSession.self, from: $0.payload) }
    }

    func deleteSession(id: UUID) throws {
        let found = try context.fetch(FetchDescriptor<StoredSession>(predicate: #Predicate { $0.id == id }))
        found.forEach { context.delete($0) }
        try context.save()
        changeToken += 1
    }
}
