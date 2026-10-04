#if DEBUG
import Foundation
import SwiftData
import CoreLocation

/// Simulator integration checks run against the actual models, actor and rendering functions.
@MainActor
enum EngineeringChecks {
    static func run() async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("engineering-checks.txt")
        var lines: [String] = []
        func heartbeat(_ message: String) {
            try? ("RUNNING: " + message + "\n")
                .write(to: output, atomically: true, encoding: .utf8)
        }
        heartbeat("engineering checks started")
        do {
            let schema = Schema([WorkoutSession.self, RoutePoint.self, LapRecord.self, WorkoutGoal.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let writer = await Task.detached { HealthImportWriter(modelContainer: container) }.value
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let points = (0..<40_000).map { index in
                HealthImportRoutePoint(latitude: 22.6 + Double(index) * 0.000001,
                                       longitude: 120.3, altitude: 10, timestamp: start.addingTimeInterval(Double(index)),
                                       speed: 2, distanceFromStart: Double(index) * 2,
                                       horizontalAccuracy: 3, verticalAccuracy: 4, course: 180,
                                       speedAccuracy: 0.2, courseAccuracy: 1)
            }
            let payload = HealthImportPayload(typeRaw: "gpsRun", sportRaw: nil, startDate: start,
                                               endDate: start.addingTimeInterval(40_000), duration: 40_000,
                                               totalDistance: 80_000, averagePace: 500,
                                               elevationGain: nil, elevationLoss: nil, stepCount: nil,
                                               calories: nil, intensityScore: nil, healthKitUUID: "test-full-route",
                                               sourceApp: "Fixture", detailsJSON: "{}", routePoints: points)
            var ticks = 0
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    ticks += 1
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            let began = Date()
            heartbeat("40,000-point writer starting")
            let inserted = try await writer.insert(
                payload,
                cancellation: ImportCancellation(),
                onProgress: { saved, total in
                    let elapsed = Date().timeIntervalSince(began)
                    try? String(format: "RUNNING: persisted %d / %d points in %.1fs\n",
                                saved, total, elapsed)
                        .write(to: output, atomically: true, encoding: .utf8)
                }
            )
            ticker.cancel()
            heartbeat("writer returned after \(String(format: "%.1f", Date().timeIntervalSince(began)))s")
            guard inserted, ticks > 1 else { throw CheckError.failed("writer blocked UI executor") }

            heartbeat("fetching saved workout")
            let context = ModelContext(container)
            let saved = try context.fetch(FetchDescriptor<WorkoutSession>())
            heartbeat("workout fetched; loading relationship")
            guard saved.count == 1 else { throw CheckError.failed("saved workout count") }

            let routeCount = saved[0].routePoints.count
            heartbeat("relationship loaded: \(routeCount) points")
            guard routeCount == 40_000 else {
                throw CheckError.failed("full route point count")
            }

            heartbeat("sorting 40,000 points for fidelity check")
            let finalAccuracy = saved[0].sortedPoints.last?.courseAccuracy
            guard finalAccuracy == 1 else {
                throw CheckError.failed("accuracy persistence")
            }
            lines.append("PASS 40,000 full points + accuracy fields; UI ticks=\(ticks); write seconds=\(Date().timeIntervalSince(began))")
            let duplicate = try await writer.insert(payload, cancellation: ImportCancellation())
            guard !duplicate else { throw CheckError.failed("duplicate UUID") }
            lines.append("PASS duplicate UUID remains one workout")
            let cancelled = ImportCancellation()
            cancelled.cancel()
            do {
                try cancelled.check()
                throw CheckError.failed("cancel signal")
            } catch is CancellationError { lines.append("PASS cancellation signal") }
            let coordinates = (0..<100).map { CLLocationCoordinate2D(latitude: 22 + Double($0) * 0.00001, longitude: 120) }
            let continuous = (0..<100).map { start.addingTimeInterval(Double($0)) }
            let retained = RouteRenderer.simplify(coordinates, timestamps: continuous, tolerance: 2.5)
            let falseGaps = RouteRenderer.remapGapIndices(originalTimestamps: continuous, retainedTimestamps: retained.map { continuous[$0] })
            guard falseGaps.isEmpty else { throw CheckError.failed("simplification creates gaps") }
            let broken = continuous.enumerated().map { $0.element.addingTimeInterval($0.offset >= 50 ? 60 : 0) }
            let kept = RouteRenderer.simplify(coordinates, timestamps: broken, tolerance: 2.5)
            guard kept.contains(49), kept.contains(50),
                  RouteRenderer.remapGapIndices(originalTimestamps: broken, retainedTimestamps: kept.map { broken[$0] }).count == 1 else {
                throw CheckError.failed("real gap endpoints")
            }
            _ = RouteRenderer.segments(coordinates: coordinates, values: [1], scale: .placeholder)
            lines.append("PASS continuous simplification / true gap / short value array")
            let settings = AppSettings.shared
            let previous = settings.workoutOverrides
            settings.resetWorkoutOptions(for: "test-run")
            settings.resetWorkoutOptions(for: "test-bike")
            settings.updateWorkoutOptions(for: "test-run") { $0.gpsAutoLapDistance = 321 }
            guard settings.workoutOptions(for: "test-run").gpsAutoLapDistance == 321,
                  settings.workoutOptions(for: "test-bike").gpsAutoLapDistance == settings.gpsAutoLapDistance else {
                throw CheckError.failed("discipline isolation")
            }
            settings.workoutOverrides = previous
            lines.append("PASS per-discipline override isolation")
            lines.append("ALL CHECKS PASSED")
        } catch {
            lines.append("FAILED: \(error)")
        }
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }
    enum CheckError: Error { case failed(String) }
}
#endif
