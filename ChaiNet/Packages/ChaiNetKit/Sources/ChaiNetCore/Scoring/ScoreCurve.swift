import Foundation

/// Piecewise-linear mapping from a raw metric to a 0–100 sub-score.
///
/// Given control points (x₀, y₀) … (xₙ, yₙ) sorted by x:
///
///     x ≤ x₀        → y₀
///     x ≥ xₙ        → yₙ
///     xᵢ ≤ x ≤ xᵢ₊₁ → yᵢ + (x − xᵢ) / (xᵢ₊₁ − xᵢ) · (yᵢ₊₁ − yᵢ)
///
/// Curves are intentionally non-linear (e.g. going from 1 → 2 % loss costs far more than
/// 40 → 50 ms of latency) and reflect perceptual thresholds per metric.
public struct ScoreCurve: Sendable, Hashable, Codable {
    public struct Point: Sendable, Hashable, Codable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public var points: [Point]

    public init(_ points: [(Double, Double)]) {
        self.points = points.map { Point($0.0, $0.1) }.sorted { $0.x < $1.x }
    }

    public func score(_ x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        guard x.isFinite else { return x > 0 ? last.y : first.y }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if x >= a.x && x <= b.x {
                guard b.x > a.x else { return b.y }
                return a.y + (x - a.x) / (b.x - a.x) * (b.y - a.y)
            }
        }
        return last.y
    }

    // MARK: Standard curves (higher score = better)

    /// Download Mbps: 5 → 30, 25 → 60, 100 → 85, 300 → 95, 1000 → 100.
    public static let download = ScoreCurve([(0, 0), (5, 30), (25, 60), (100, 85), (300, 95), (1000, 100)])
    /// Upload Mbps: 1 → 20, 5 → 50, 20 → 80, 50 → 92, 200 → 100.
    public static let upload = ScoreCurve([(0, 0), (1, 20), (5, 50), (20, 80), (50, 92), (200, 100)])
    /// Idle latency ms: ≤10 → 100, 20 → 95, 40 → 85, 80 → 60, 150 → 30, ≥300 → 0.
    public static let latency = ScoreCurve([(0, 100), (10, 100), (20, 95), (40, 85), (80, 60), (150, 30), (300, 0)])
    /// Jitter ms: ≤2 → 100, 5 → 90, 15 → 70, 30 → 45, 60 → 20, ≥100 → 0.
    public static let jitter = ScoreCurve([(0, 100), (2, 100), (5, 90), (15, 70), (30, 45), (60, 20), (100, 0)])
    /// Loss %: 0 → 100, 0.1 → 95, 0.5 → 80, 1 → 65, 2.5 → 40, 5 → 15, ≥10 → 0.
    public static let loss = ScoreCurve([(0, 100), (0.1, 95), (0.5, 80), (1, 65), (2.5, 40), (5, 15), (10, 0)])
    /// Bufferbloat increase ms: ≤5 → 100, 30 → 85, 60 → 65, 200 → 30, ≥400 → 0.
    public static let bufferbloat = ScoreCurve([(0, 100), (5, 100), (30, 85), (60, 65), (200, 30), (400, 0)])
    /// Stability score passes through unchanged (already 0–100).
    public static let identity = ScoreCurve([(0, 0), (100, 100)])
}
