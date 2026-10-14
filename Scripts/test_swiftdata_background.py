#!/usr/bin/env python3
"""Native SwiftData in-memory smoke test on macOS, using production models/reader.
Sport catalog and date formatter stubs isolate unrelated HealthKit/UI dependencies.
No user's database or route is opened. This does not replace iPhone UI acceptance.
"""
import ast, platform, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
if platform.system() != 'Darwin':
    raise SystemExit('This runtime test requires the macOS SwiftData SDK.')
def source(name): return (ROOT / 'GPSTracker' / name).read_text()
syntax = ast.parse((ROOT / 'Scripts/test_portable_integration.py').read_text())
stubs = next(ast.literal_eval(node.value) for node in syntax.body if isinstance(node, ast.Assign) and any(isinstance(x, ast.Name) and x.id == 'stubs' for x in node.targets))
stubs += '''
enum Fmt { static let shortDayFormatter = DateFormatter() }
final class ReaderThreadProbe: @unchecked Sendable {
    static let shared = ReaderThreadProbe()
    private let lock = NSLock()
    private var reads = 0
    func record() { precondition(!Thread.isMainThread, "GPS reader blocked the main thread"); lock.lock(); reads += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
}
@MainActor final class Heartbeat { var count = 0 }
'''
coordinator = source('Core/Calibration/CalibrationCoordinator.swift')
helper = coordinator[coordinator.index('enum CalibrationSessionAnalyzer {'):coordinator.index('@ModelActor')]
reader = source('Core/WorkoutInsightsStore.swift').replace(
    '        let sessions = try modelContext.fetch(',
    '        ReaderThreadProbe.shared.record()\n        let sessions = try modelContext.fetch(', 1)
harness = '''
@main struct NativeSwiftDataCheck {
    @MainActor static func main() async throws {
        let schema = Schema([WorkoutSession.self, RoutePoint.self, LapRecord.self, WorkoutGoal.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let base = Date(timeIntervalSince1970: 1700000000)
        for index in 0..<3 {
            let start = base.addingTimeInterval(Double(index) * 86400)
            let session = WorkoutSession(type: .gpsRun, startDate: start, endDate: start.addingTimeInterval(7000), duration: 7000,
                                         totalDistance: 21000, averagePace: 7000 / 21, stepCount: 10000)
            session.routePoints = (0..<7001).map { i in
                RoutePoint(latitude: 25 + Double(i) * 0.000001, longitude: 121 + Double(i) * 0.000001,
                           altitude: 10, timestamp: start.addingTimeInterval(Double(i)), speed: 3,
                           distanceFromStart: Double(i) * 3, horizontalAccuracy: 5)
            }
            context.insert(session)
        }
        try context.save()
        let pulse = Heartbeat()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                pulse.count += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let store = WorkoutInsightsStore()
        store.configure(container: container)
        let started = Date()
        await store.loadIfNeeded()
        heartbeat.cancel()
        guard let result = store.result else { fatalError(store.error ?? "Missing reader output") }
        precondition(result.integrity.total == 3 && result.clusters.count == 1 && result.clusters[0].count == 3)
        precondition(result.achievements.first { $0.id == "routes" }?.current == 3)
        precondition(result.efforts.first { $0.distance == 3000 }?.duration == 1000)
        precondition(pulse.count > 1, "Main actor heartbeat stalled")
        let reads = ReaderThreadProbe.shared.count
        await store.loadIfNeeded()
        precondition(ReaderThreadProbe.shared.count == reads, "Returning to another tab recomputed unchanged routes")
        precondition(try context.fetchCount(FetchDescriptor<RoutePoint>()) == 21003)
        print("Native SwiftData background reader passed: 3 workouts, 21003 unchanged points, main heartbeat \\(pulse.count), cache reused, seconds \\(Date().timeIntervalSince(started)).")
    }
}
'''
# Throwing calls cannot be evaluated inside precondition's non-throwing autoclosure.
harness = harness.replace('        precondition(try context.fetchCount(FetchDescriptor<RoutePoint>()) == 21003)',
                          '        let pointCount = try context.fetchCount(FetchDescriptor<RoutePoint>())\n        precondition(pointCount == 21003)')
names = ['Core/Calibration/MeasurementPolicy.swift', 'Core/Calibration/StrideValidation.swift',
         'Core/Calibration/WorkoutTime.swift', 'Core/Calibration/PerformanceWindow.swift', 'Core/Calibration/BackgroundFactory.swift',
         'Core/StatsEngine.swift', 'Core/BestEfforts.swift', 'Core/RouteCluster.swift',
         'Core/Achievements.swift', 'Core/DataIntegrity.swift', 'Core/CoverageGap.swift']
with tempfile.TemporaryDirectory(prefix='gpstracker-native-swiftdata-') as directory:
    path = Path(directory)
    text = stubs + source('Models/WorkoutModels.swift') + ''.join(source(name) for name in names) + helper + reader + harness
    (path / 'NativeCheck.swift').write_text(text)
    architecture = platform.machine()
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', architecture + '-apple-macosx15.0',
                    str(path / 'NativeCheck.swift'), '-o', str(path / 'native-check')], check=True)
    subprocess.run([str(path / 'native-check')], check=True)
