import Foundation
import SwiftData
import Combine

struct CalibrationReport: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var version = 1
    var completed = false
    var scanned = 0
    var healthScanned: Int? = nil
    var existing = 0
    var added = 0
    var gradeCounts: [String: Int] = [:]
    var sourceCounts: [String: Int] = [:]
    var profileCounts: [String: Int] = [:]
    var reasonCounts: [String: Int] = [:]
    var eligible = 0
    var pending = 0
    var excluded = 0
    var insufficient = 0
    var outcomes: [String: ValidationOutcome] = [:]
    var message = ""
}

enum CalibrationReportStore {
    static let key = "calibration.reports.v1"
    static var reports: [CalibrationReport] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CalibrationReport].self, from: data)) ?? []
    }
    static func save(_ report: CalibrationReport) {
        var items = reports.filter { $0.id != report.id }
        items.insert(report, at: 0)
        if let data = try? JSONEncoder().encode(Array(items.prefix(20))) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func restore(_ incoming: [CalibrationReport]) {
        for report in incoming.reversed() where !reports.contains(where: { $0.id == report.id }) { save(report) }
    }
}

enum CalibrationSessionAnalyzer {
    static func identity(_ s: WorkoutSession) -> WorkoutIdentity {
        WorkoutIdentity(id: s.id.uuidString, healthUUID: s.healthKitUUID, originID: s.evidence.originSessionID,
                        activity: s.type.isStepBased || s.type == .gpsRun || s.type == .gpsHike ? s.type.strideProfile.rawValue : s.sportRaw ?? s.typeRaw, start: s.startDate, end: s.endDate, distance: s.totalDistance)
    }
    static func evaluate(_ s: WorkoutSession) -> CalibrationDecision {
        let e = s.evidence
        let gps: GPSQuality? = e.method == .independentGPS ? GPSQualityAnalyzer.analyze(
            s.routePoints.map { GPSObservation(latitude: $0.latitude, longitude: $0.longitude, date: $0.timestamp, accuracy: $0.horizontalAccuracy) },
            start: s.startDate, end: s.endDate, pauses: e.pauseIntervals) : nil
        let supported = s.stepsAreMeaningful && [.gpsRun, .gpsHike, .walk, .run, .treadmill, .ruck].contains(s.type)
        return CalibrationEligibility.evaluate(evidence: e, distance: s.totalDistance, steps: s.stepCount,
                                               duration: s.duration, profile: s.type.strideProfile.rawValue,
                                               supported: supported, gps: gps, userExcluded: s.trainingExcluded)
    }
}

@ModelActor
private actor CalibrationAnalysisWriter {
    func analyze(incremental: Bool, progress: @Sendable (Int, Int) async -> Void) async throws -> (CalibrationReport, [String: [ValidationSample]]) {
        modelContext.autosaveEnabled = false
        var saved = false
        defer { if !saved { modelContext.rollback() } }
        // All heavyweight route traversal runs off the UI executor.
        let sessions = try modelContext.fetch(FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startDate)]))
        var report = CalibrationReport()
        var groups: [String: [ValidationSample]] = [:]
        var acceptedIdentities: [WorkoutIdentity] = []
        var personal: [String: [Double]] = [:]
        for (index, session) in sessions.enumerated() {
            try Task.checkCancellation()
            var decision = incremental ? session.calibrationDecision ?? CalibrationSessionAnalyzer.evaluate(session) : CalibrationSessionAnalyzer.evaluate(session)
            if decision.reasons.contains(.duplicateWorkout) || decision.reasons.contains(.suspectPersonalDistribution) { decision = CalibrationSessionAnalyzer.evaluate(session) }
            let identity = CalibrationSessionAnalyzer.identity(session)
            let profile = session.type.strideProfile.rawValue
            if decision.eligible {
                if acceptedIdentities.contains(where: { $0.matches(identity) }) {
                    decision.eligible = false; decision.grade = .d; decision.reasons.append(.duplicateWorkout)
                } else if let stride = decision.stride, let distribution = personal[profile], distribution.count >= 6 {
                    let sorted = distribution.sorted(), median = sorted[sorted.count / 2]
                    let deviations = sorted.map { abs($0 - median) }.sorted()
                    let mad = deviations[deviations.count / 2]
                    if abs(stride - median) > max(0.45 * median, 4 * mad) {
                        decision.eligible = false; decision.grade = .b; decision.reasons.append(.suspectPersonalDistribution)
                    }
                }
            }
            if decision.eligible, let distance = session.totalDistance, let steps = session.stepCount {
                acceptedIdentities.append(identity)
                personal[profile, default: []].append(distance / Double(steps))
                groups[profile, default: []].append(ValidationSample(workoutID: session.id.uuidString, date: session.startDate, distance: distance, steps: steps))
                report.eligible += 1
            } else if decision.grade == .d { report.excluded += 1 }
            else if decision.grade == .b { report.pending += 1 }
            else { report.insufficient += 1 }
            session.calibrationDecision = decision
            report.scanned += 1
            report.gradeCounts[decision.grade.rawValue, default: 0] += 1
            report.sourceCounts[session.evidence.sourceBundle ?? session.sourceApp ?? "來源未知", default: 0] += 1
            report.profileCounts[profile, default: 0] += decision.eligible ? 1 : 0
            for reason in decision.reasons { report.reasonCounts[reason.rawValue, default: 0] += 1 }
            if index % 20 == 0 || index + 1 == sessions.count { await progress(index + 1, sessions.count) }
        }
        do { try Task.checkCancellation(); try modelContext.save(); saved = true }
        catch { modelContext.rollback(); throw error }
        return (report, groups)
    }
}

@MainActor
final class CalibrationCoordinator: ObservableObject {
    static let shared = CalibrationCoordinator()
    @Published private(set) var isWorking = false
    @Published private(set) var stage = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var latest: CalibrationReport? = CalibrationReportStore.reports.first
    private var writer: CalibrationAnalysisWriter?
    private var analysisTask: Task<(CalibrationReport, [String: [ValidationSample]]), Error>?
    private var cancelled = false

    func configure(container: ModelContainer) async {
        guard !DatabaseHealth.needsAttention else { return }
        writer = await Task.detached { CalibrationAnalysisWriter(modelContainer: container) }.value
    }
    func cancel() {
        cancelled = true
        HealthKitImporter.shared.cancel()
        analysisTask?.cancel()
        stage = "正在安全取消，已保存的運動保留"
    }
    func run(importHealth: Bool, incremental: Bool = false) async {
        guard !isWorking, let writer, !DatabaseHealth.needsAttention else { return }
        isWorking = true; cancelled = false; progress = 0
        defer { isWorking = false; analysisTask = nil }
        var imported = ImportResult()
        if importHealth {
            let health = HealthKitManager.shared
            stage = "確認健康權限…"
            if !health.isReady {
                if await health.requestAuthorization() { AppSettings.shared.healthKitEnabled = true }
            }
            guard !cancelled else { finishCancelled(); return }
            if health.isReady {
                stage = "匯入完整歷史與原始路線…"
                imported = await HealthKitImporter.shared.importWorkouts(range: .all, existing: [], includeRoutes: true)
                if let error = imported.error { stage = error; finishCancelled(message: error); return }
                if imported.cancelled { cancelled = true }
            }
        }
        guard !cancelled else { finishCancelled(); return }
        stage = "逐筆來源、時間、GPS 品質分析與去重…"
        let task = Task {
            try await writer.analyze(incremental: incremental) { done, total in
                await MainActor.run {
                    self.progress = Double(done) / Double(max(1, total))
                    self.stage = "來源與品質分析：第 \(done) / \(total) 筆"
                }
            }
        }
        analysisTask = task
        do {
            var (report, groups) = try await task.value
            guard !cancelled else { finishCancelled(); return }
            stage = "按場次保留獨立驗證，比較舊模型…"
            for profile in [StrideProfile.walking, .running, .ruck] {
                let outcome = CalibrationValidator.validate(samples: groups[profile.rawValue] ?? [], baseline: StrideCalibration.stride(profile))
                report.outcomes[profile.rawValue] = outcome
            }
            // Apply only after the complete dataset has been saved and cancellation checked.
            guard !cancelled else { finishCancelled(); return }
            for profile in [StrideProfile.walking, .running, .ruck] {
                if let outcome = report.outcomes[profile.rawValue], outcome.applied {
                    StrideCalibration.applyValidated(outcome, profile: profile)
                }
            }
            report.healthScanned = importHealth ? imported.scanned : nil
            report.existing = imported.skipped; report.added = imported.imported
            report.completed = true
            report.message = "完成 \(report.scanned) 筆分析；A/B/C/D 合計等於掃描數。排除理由為多標籤，另行計數。"
            CalibrationReportStore.save(report); latest = report; stage = report.message
            UserDefaults.standard.set(true, forKey: "calibration.analysisEnabled")
        } catch {
            finishCancelled(message: cancelled ? "已取消；未套用候選模型，原有運動保持完整" : "分析未完成：\(error.localizedDescription)")
        }
    }
    private func finishCancelled(message: String = "已取消；未套用候選模型，已匯入紀錄保留") {
        var report = CalibrationReport(); report.message = message
        CalibrationReportStore.save(report); latest = report; stage = message
    }
    func analyzeIfEnabled() async {
        guard UserDefaults.standard.bool(forKey: "calibration.analysisEnabled") else { return }
        await run(importHealth: false, incremental: true)
    }
}
