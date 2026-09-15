import Foundation

/// 把一堆歷史樣本算成「步幅 + 精準度」。
///
/// 精準度由三件事決定：
/// 1. 有效樣本量（近期資料權重高，三四年前的資料權重低）
/// 2. 一致性（各次算出來的步幅彼此接近才可信）
/// 3. 新鮮度（最近有沒有新資料，身體狀況會變）
enum StrideAutoCalibrator {

    /// 樣本過濾條件
    static func isPlausible(_ sample: StrideSample) -> Bool {
        sample.stride > 0.35 && sample.stride < 2.1
            && sample.distance > 300
            && sample.steps > 300
    }

    static func compute(samples input: [StrideSample], profile: StrideProfile) -> CalibrationResult {
        let samples = input.filter { $0.profile == profile && isPlausible($0) }

        guard !samples.isEmpty else {
            return CalibrationResult(profile: profile,
                                     stride: StrideCalibration.defaultStride(profile),
                                     confidence: 0,
                                     rawSampleCount: 0,
                                     weightedSampleCount: 0,
                                     consistency: 0,
                                     recencyScore: 0,
                                     coverageScore: 0,
                                     coefficientOfVariation: 0,
                                     spanDays: 0,
                                     newestDate: nil,
                                     oldestDate: nil,
                                     sourceBreakdown: [:])
        }

        // 先用中位數去掉離群值，再做加權平均
        let sorted = samples.map { $0.stride }.sorted()
        let median = sorted[sorted.count / 2]
        let kept = samples.filter { abs($0.stride - median) / median < 0.28 }
        let working = kept.isEmpty ? samples : kept

        let totalWeight = working.reduce(0.0) { $0 + $1.weight }
        let weightedMean = totalWeight > 0
            ? working.reduce(0.0) { $0 + $1.stride * $1.weight } / totalWeight
            : median

        // 加權標準差 → 變異係數
        let variance = totalWeight > 0
            ? working.reduce(0.0) { $0 + $1.weight * pow($1.stride - weightedMean, 2) } / totalWeight
            : 0
        let stdDev = sqrt(max(0, variance))
        let cv = weightedMean > 0 ? stdDev / weightedMean : 1

        // 1. 樣本量：有效權重 6 左右開始可信，12 以上接近飽和
        let coverage = 1 - exp(-totalWeight / 6.0)
        // 2. 一致性：變異係數 12% 以上視為不穩
        let consistency = min(1, max(0, 1 - cv / 0.12))
        // 3. 新鮮度：30 天內滿分，一年後歸零
        let newest = working.map { $0.date }.max()
        let newestAge = newest.map { max(0, Date().timeIntervalSince($0) / 86400) } ?? 999
        let recency = newestAge <= 30 ? 1.0 : max(0, 1 - (newestAge - 30) / 335)

        let confidence = min(1, 0.5 * coverage + 0.3 * consistency + 0.2 * recency)

        let oldest = working.map { $0.date }.min()
        let span = (newest != nil && oldest != nil)
            ? Int(newest!.timeIntervalSince(oldest!) / 86400)
            : 0

        var breakdown: [StrideSample.Source: Int] = [:]
        for sample in working {
            breakdown[sample.source, default: 0] += 1
        }

        return CalibrationResult(profile: profile,
                                 stride: weightedMean,
                                 confidence: confidence,
                                 rawSampleCount: working.count,
                                 weightedSampleCount: totalWeight,
                                 consistency: consistency,
                                 recencyScore: recency,
                                 coverageScore: coverage,
                                 coefficientOfVariation: cv,
                                 spanDays: span,
                                 newestDate: newest,
                                 oldestDate: oldest,
                                 sourceBreakdown: breakdown)
    }

    /// 從 App 自己的紀錄取樣（不需要健康權限）
    @MainActor
    static func samples(from sessions: [WorkoutSession]) -> [StrideSample] {
        sessions.compactMap { session in
            guard let distance = session.totalDistance,
                  let steps = session.stepCount,
                  steps > 300,
                  distance > 300,
                  session.distanceSource == .gps || session.distanceSource == .manual else { return nil }
            return StrideSample(stride: distance / Double(steps),
                                distance: distance,
                                steps: steps,
                                date: session.startDate,
                                source: session.distanceSource == .manual ? .manual : .gpsSession,
                                profile: session.type.strideProfile)
        }
    }
}
