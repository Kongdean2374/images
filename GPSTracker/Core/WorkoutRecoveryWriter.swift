import Foundation
import SwiftData

@ModelActor
actor WorkoutRecoveryWriter {
    func save(snapshot: ActiveWorkoutSnapshot, bodyWeight: Double, syncHealth: Bool) async throws -> UUID {
        modelContext.autosaveEnabled = false
        let identifier = snapshot.recoveredSessionID
        let query = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == identifier })
        let session: WorkoutSession
        if let existing = try modelContext.fetch(query).first {
            session = existing
        } else {
            session = ActiveWorkoutStore.buildSession(from: snapshot, bodyWeight: bodyWeight)
            modelContext.insert(session)
            do { try modelContext.save() }
            catch { modelContext.rollback(); throw error }
        }
        // Persistence is complete before the last recovery copy is cleared.
        await MainActor.run { ActiveWorkoutStore.shared.clear() }
        if syncHealth { Task { await syncSavedSession(id: identifier) } }
        return identifier
    }
    private func syncSavedSession(id: UUID) async {
        let query = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })
        guard let session = try? modelContext.fetch(query).first, !session.healthKitSynced else { return }
        let values = WorkoutSnapshot(session: session)
        if let uuid = await HealthKitManager.shared.save(values) {
            session.healthKitUUID = uuid; session.healthKitSynced = true
            try? modelContext.save()
        }
    }

}
