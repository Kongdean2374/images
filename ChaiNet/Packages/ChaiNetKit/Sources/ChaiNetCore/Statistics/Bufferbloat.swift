import Foundation

/// Bufferbloat grade (latency increase under load).
public enum BufferbloatGrade: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case aPlus = "A+"
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case f = "F"

    /// Grade from the latency increase under load (ms).
    ///
    ///     < 5     A+   (no perceptible queueing)
    ///     < 30    A
    ///     < 60    B
    ///     < 200   C
    ///     < 400   D
    ///     ≥ 400   F
    public static func from(increaseMs: Double) -> BufferbloatGrade {
        switch increaseMs {
        case ..<5: return .aPlus
        case ..<30: return .a
        case ..<60: return .b
        case ..<200: return .c
        case ..<400: return .d
        default: return .f
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    /// `A+ < A < … < F`, i.e. "less than" means *better*.
    public static func < (lhs: BufferbloatGrade, rhs: BufferbloatGrade) -> Bool { lhs.rank < rhs.rank }
}

public struct BufferbloatResult: Codable, Sendable, Hashable {
    public var idleMedianMs: Double
    public var downloadLoadedMedianMs: Double?
    public var uploadLoadedMedianMs: Double?
    /// max(0, downloadLoaded.median − idle.median)
    public var downloadIncreaseMs: Double?
    /// max(0, uploadLoaded.median − idle.median)
    public var uploadIncreaseMs: Double?
    public var downloadGrade: BufferbloatGrade?
    public var uploadGrade: BufferbloatGrade?
    /// Worst of the two directional grades.
    public var grade: BufferbloatGrade
}

/// Compares idle latency with latency measured while the link is saturated.
///
/// Medians (not averages) are compared because a loaded link produces a long tail and the
/// median reflects the queueing delay a typical packet experiences.
///
///     increase(dir) = max(0, median(loaded_dir) − median(idle))
///     grade(dir)    = BufferbloatGrade.from(increase(dir))
///     grade         = worst(grade(download), grade(upload))
public enum BufferbloatCalculator {
    public static func evaluate(idle: LatencyStatistics, downloadLoaded: LatencyStatistics?, uploadLoaded: LatencyStatistics?) -> BufferbloatResult? {
        guard let idleMedian = idle.rtt?.median else { return nil }
        let dlMedian = downloadLoaded?.rtt?.median
        let ulMedian = uploadLoaded?.rtt?.median
        guard dlMedian != nil || ulMedian != nil else { return nil }

        let dlIncrease = dlMedian.map { max(0, $0 - idleMedian) }
        let ulIncrease = ulMedian.map { max(0, $0 - idleMedian) }
        let dlGrade = dlIncrease.map(BufferbloatGrade.from(increaseMs:))
        let ulGrade = ulIncrease.map(BufferbloatGrade.from(increaseMs:))
        let worst = [dlGrade, ulGrade].compactMap { $0 }.max()!

        return BufferbloatResult(
            idleMedianMs: idleMedian,
            downloadLoadedMedianMs: dlMedian,
            uploadLoadedMedianMs: ulMedian,
            downloadIncreaseMs: dlIncrease,
            uploadIncreaseMs: ulIncrease,
            downloadGrade: dlGrade,
            uploadGrade: ulGrade,
            grade: worst)
    }
}
