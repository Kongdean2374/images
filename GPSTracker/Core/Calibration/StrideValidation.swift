import Foundation

struct ValidationSample: Codable, Sendable {
    var workoutID: String
    var date: Date
    var distance: Double
    var steps: Int
    var stride: Double { distance / Double(steps) }
}
struct ValidationOutcome: Codable, Sendable {
    var applied = false
    var reason: String
    var testCount = 0
    var candidateStride: Double?
    var baselineError: Double?
    var candidateError: Double?
    var absoluteErrorMeters: Double?
    var worstRelativeError: Double?
    var signedRelativeError: Double?
    var sampleIDs: [String] = []
}
enum CalibrationValidator {
    static func validate(samples: [ValidationSample], baseline: Double) -> ValidationOutcome {
        let unique = Dictionary(grouping: samples, by: \.workoutID).values.compactMap { $0.first }
            .filter { $0.distance > 300 && $0.steps > 300 }.sorted { $0.date < $1.date }
        guard unique.count >= 6 else { return ValidationOutcome(reason: "可信獨立場次不足 6 筆，保留舊模型；尚無足夠驗證") }
        let testCount = max(2, unique.count / 3)
        let tests = Array(unique.suffix(testCount))
        // Strict temporal separation also excludes simultaneous cross-device records.
        let cutoff = tests[0].date
        let train = unique.dropLast(testCount).filter { $0.date < cutoff }
        guard train.count >= 4 else { return ValidationOutcome(reason: "無足夠時間分離的訓練與驗證場次") }
        let sorted = train.map(\.stride).sorted()
        let median = sorted[sorted.count / 2]
        let madValues = sorted.map { abs($0 - median) }.sorted()
        let mad = madValues[madValues.count / 2]
        let kept = train.filter { abs($0.stride - median) <= max(0.12 * median, 3 * mad) }
        let candidate = kept.reduce(0) { $0 + $1.distance } / Double(kept.reduce(0) { $0 + $1.steps })
        let errors = tests.map { abs(Double($0.steps) * candidate - $0.distance) / $0.distance }
        let oldErrors = tests.map { abs(Double($0.steps) * baseline - $0.distance) / $0.distance }
        let error = errors.reduce(0, +) / Double(testCount)
        let oldError = oldErrors.reduce(0, +) / Double(testCount)
        let worst = errors.max() ?? 1
        let improved = error + 0.005 < oldError && worst <= (oldErrors.max() ?? 0) + 0.005 && worst < 0.25 && abs(candidate - baseline) / baseline <= 0.25
        return ValidationOutcome(applied: improved, reason: improved ? "獨立時間留出驗證改善，已套用" : "候選未明確改善、最差誤差過大或步幅變動過大，保留舊模型", testCount: testCount,
                                 candidateStride: candidate, baselineError: oldError, candidateError: error,
                                 absoluteErrorMeters: tests.reduce(0) { $0 + abs(Double($1.steps) * candidate - $1.distance) } / Double(testCount),
                                 worstRelativeError: worst,
                                 signedRelativeError: tests.reduce(0) { $0 + (Double($1.steps) * candidate - $1.distance) / $1.distance } / Double(testCount),
                                 sampleIDs: unique.map(\.workoutID))
    }
}

/// Integrates only actual cumulative callback increments. No fabricated per-second samples.
struct StepDistanceAccumulator {
    private(set) var steps = 0
    private(set) var distance = 0.0
    private(set) var smoothedCadence: Double?
    private var lastRawSteps = 0
    private var lastSystemDistance: Double?
    private var lastDate: Date?
    mutating func rebase() { lastRawSteps = 0; lastSystemDistance = nil; lastDate = nil; smoothedCadence = nil }
    mutating func ingest(rawSteps: Int, systemDistance: Double?, cadence: Double?, date: Date,
                         stride: Double, calibrated: Bool, suppress: Bool = false) -> (steps: Int, distance: Double, system: Bool)? {
        guard rawSteps >= 0, lastDate.map({ date > $0 }) ?? true else { return nil }
        guard rawSteps >= lastRawSteps else { return nil }
        let delta = rawSteps - lastRawSteps
        let previousSystem = lastSystemDistance ?? 0
        lastRawSteps = rawSteps
        lastDate = date
        if let systemDistance, systemDistance.isFinite, systemDistance >= previousSystem { lastSystemDistance = systemDistance }
        if let cadence, cadence.isFinite, (25...260).contains(cadence) {
            smoothedCadence = smoothedCadence.map { $0 * 0.65 + cadence * 0.35 } ?? cadence
        }
        guard delta > 0, !suppress else { return nil }
        let systemIncrement = systemDistance.map { $0 - previousSystem }
        let useSystem = !calibrated && systemIncrement.map { $0.isFinite && $0 > 0 && $0 / Double(delta) <= 2.8 } == true
        let increment = useSystem ? systemIncrement! : Double(delta) * stride
        steps += delta
        distance += max(0, increment)
        return (delta, max(0, increment), useSystem)
    }
}

struct EstimateWindow: Codable, Sendable {
    var start: Date
    var end: Date
    var steps: Int
    var distance: Double
    var cadence: Double?
    var profile: String
    var source: String
    var motion: String
}
