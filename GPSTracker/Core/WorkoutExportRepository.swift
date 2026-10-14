import Foundation
import SwiftData

enum WorkoutExportFormat: Sendable { case gpx, tcx, csv }

@ModelActor
actor WorkoutExportWriter {
    func sessionFile(id: UUID, format: WorkoutExportFormat) throws -> URL? {
        let requested = id
        let descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == requested })
        guard let session = try modelContext.fetch(descriptor).first else { throw CocoaError(.fileNoSuchFile) }
        switch format {
        case .gpx: return RouteFileExporter.gpxFile(for: session)
        case .tcx: return RouteFileExporter.tcxFile(for: session)
        case .csv: return DataExporter.routeCSV(session: session)
        }
    }
    func historyCSV() throws -> URL? {
        DataExporter.csv(sessions: try modelContext.fetch(FetchDescriptor<WorkoutSession>()))
    }
}

@MainActor
enum WorkoutExportRepository {
    private(set) static var writer: WorkoutExportWriter?
    static func configure(container: ModelContainer) async {
        guard !DatabaseHealth.needsAttention else { return }
        writer = await Task.detached { WorkoutExportWriter(modelContainer: container) }.value
    }
}
