import SwiftUI
import ChaiNetCore

/// Real-time throughput chart: a plain line chart, redrawn when data arrives.
///
///     bins    fixed, time-aligned buckets of `binSeconds` (0.5 s, doubling for long tests);
///             a completed bucket = bytes × 8 / duration and never changes afterwards
///     head    the current readout at the latest sample time (the only point that moves)
///     line    straight segments between points (no spline smoothing, no glow, no marker)
///     y-axis  niceCeiling(max(P90 of completed buckets × 1.25, head × 1.15)) — a single start-up
///             burst can't pin the axis at 1–2 Gbps; values above it are clipped at the top
struct LiveThroughputChart: View {
    /// Raw 100 ms samples of the current transfer.
    let samples: [SpeedSample]
    let lastSampleAt: Date?
    let unit: SpeedUnit
    let color: Color
    var style: ChartStyle = .area
    var averageMbps: Double?
    /// Minimum bucket width (upload progress batching needs wider buckets).
    var minimumBinSeconds: Double = 0.5
    var height: CGFloat = 180
    /// Current readout (Mbps) drawn at the latest sample time.
    var head: Double?

    var body: some View {
        Canvas { g, size in
            draw(in: &g, size: size)
        }
        .frame(height: height)
        .accessibilityLabel("即時速度圖表")
    }

    struct Bin: Equatable { var t: Double; var mbps: Double }

    /// Completed, time-aligned buckets. Bucket i covers (i·b, (i+1)·b]; plotted at its end.
    static func bins(_ samples: [SpeedSample], binSeconds b: Double) -> [Bin] {
        guard let last = samples.last, b > 0 else { return [] }
        let completed = Int((last.offset / b).rounded(.down))
        guard completed > 0 else { return [] }
        var bytes = [Int64](repeating: 0, count: completed)
        var duration = [Double](repeating: 0, count: completed)
        for s in samples {
            let i = Int(((s.offset - 1e-9) / b).rounded(.down))
            guard i >= 0, i < completed else { continue }
            bytes[i] += s.intervalBytes
            duration[i] += s.intervalDuration
        }
        return (0..<completed).compactMap { i in
            duration[i] > 0 ? Bin(t: Double(i + 1) * b, mbps: Double(bytes[i]) * 8 / duration[i] / 1_000_000) : nil
        }
    }

    /// 0.5, 1, 2, 4 … s so that at most ~1 bucket per 3 pt is drawn.
    static func binSeconds(duration: Double, width: CGFloat, minimum: Double) -> Double {
        var b = max(0.5, minimum)
        while duration / b > Double(max(width, 60)) / 3 { b *= 2 }
        return b
    }

    private func draw(in g: inout GraphicsContext, size: CGSize) {
        let leftPad: CGFloat = 4, rightPad: CGFloat = 44, topPad: CGFloat = 10, bottomPad: CGFloat = 18
        let plot = CGRect(x: leftPad, y: topPad, width: size.width - leftPad - rightPad, height: size.height - topPad - bottomPad)

        let tNow = samples.last?.offset ?? 0
        let b = Self.binSeconds(duration: max(tNow, 1), width: plot.width, minimum: minimumBinSeconds)
        let bins = Self.bins(samples, binSeconds: b)
        let headMbps = head

        // Robust range: typical speed, not the single highest burst.
        let sorted = bins.map(\.mbps).sorted()
        let typical = sorted.isEmpty ? 0 : (sorted.count >= 3 ? Percentile.value(0.9, sorted: sorted)! : sorted.last!)
        let robustMbps = max(typical * 1.25, (headMbps ?? 0) * 1.15)
        let resolved = SpeedFormatter.resolve(unit, mbps: max(robustMbps, 0.001))
        let k = resolved.perMbps
        let yMax = LiveScale.niceCeiling(max(robustMbps * k, 0.1))
        let tMax = max(5, tNow)

        // Grid + labels.
        let gridColor = Color.secondary.opacity(0.18)
        for i in 0...3 {
            let v = yMax * Double(i) / 3
            let y = plot.maxY - plot.height * CGFloat(i) / 3
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            g.stroke(line, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.5, dash: i == 0 ? [] : [3, 4]))
            g.draw(Text(Self.label(v)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                   at: CGPoint(x: plot.maxX + 6, y: y), anchor: .leading)
        }
        g.draw(Text(resolved.symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary),
               at: CGPoint(x: plot.maxX + 6, y: plot.minY - 2), anchor: .bottomLeading)
        g.draw(Text("0 秒").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX, y: plot.maxY + 3), anchor: .topLeading)
        g.draw(Text("\(Int(tMax.rounded())) 秒").font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
               at: CGPoint(x: plot.maxX, y: plot.maxY + 3), anchor: .topTrailing)

        func position(_ t: Double, _ mbps: Double) -> CGPoint {
            CGPoint(x: plot.minX + plot.width * CGFloat(t / tMax),
                    y: plot.maxY - plot.height * CGFloat(min(mbps * k, yMax) / max(yMax, 0.001)))
        }
        var xy = [CGPoint(x: plot.minX, y: plot.maxY)] + bins.map { position($0.t, $0.mbps) }
        if let headMbps, tNow > (bins.last?.t ?? 0) { xy.append(position(tNow, headMbps)) }
        guard xy.count >= 2 else {
            g.draw(Text("等待資料…").font(.footnote).foregroundStyle(.secondary), at: CGPoint(x: plot.midX, y: plot.midY))
            return
        }

        if style == .bar {
            let w = max(1.5, plot.width * CGFloat(b / tMax) * 0.7)
            for p in xy.dropFirst() {
                let r = CGRect(x: p.x - w, y: p.y, width: w, height: plot.maxY - p.y)
                g.fill(Path(roundedRect: r, cornerRadius: min(w / 2, 3)), with: .linearGradient(Gradient(colors: [color, color.opacity(0.35)]),
                       startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            }
        } else {
            let curve = Self.linePath(xy)
            if style == .area {
                var fill = curve
                fill.addLine(to: CGPoint(x: xy.last!.x, y: plot.maxY))
                fill.addLine(to: CGPoint(x: xy.first!.x, y: plot.maxY))
                fill.closeSubpath()
                g.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.40), color.opacity(0.02)]),
                                                   startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            }
            g.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }

        if let avg = averageMbps, avg > 0 {
            let y = position(0, avg).y
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            g.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            g.draw(Text("平均").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX + 2, y: y - 2), anchor: .bottomLeading)
        }
    }

    /// Smooth monotone cubic curve through the points (Fritsch–Carlson): rounded like a hand-drawn
    /// line but never overshoots above a peak or below zero, and a segment only depends on its
    /// neighbours, so already-drawn parts stay still while new data arrives.
    static func linePath(_ p: [CGPoint]) -> Path {
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 2 else {
            p.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        let n = p.count
        var d = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = p[i + 1].x - p[i].x
            d[i] = dx > 0 ? (p[i + 1].y - p[i].y) / dx : 0
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
        }
        for i in 0..<(n - 1) where d[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let h = a * a + b * b
            if h > 9 {
                let t = 3 / h.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        for i in 0..<(n - 1) {
            let dx = (p[i + 1].x - p[i].x) / 3
            path.addCurve(to: p[i + 1],
                          control1: CGPoint(x: p[i].x + dx, y: p[i].y + m[i] * dx),
                          control2: CGPoint(x: p[i + 1].x - dx, y: p[i + 1].y - m[i + 1] * dx))
        }
        return path
    }

    static func label(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f", v) : (v >= 1 ? String(format: "%.1f", v) : String(format: "%.2f", v))
    }
}

/// Eased y-axis maximum (critically damped, frame-rate independent).
final class LiveScale {
    private var value: Double = 0
    private var last: Date?

    func step(toward target: Double, now: Date) -> Double {
        defer { last = now }
        guard let last, value > 0 else { value = target; return value }
        let dt = min(0.1, max(0, now.timeIntervalSince(last)))
        // Grow quickly (the line must not leave the chart), shrink a little slower.
        value += (target - value) * (1 - exp(-dt * (target > value ? 12 : 6)))
        return value
    }

    /// 1 / 2 / 2.5 / 5 × 10ⁿ ceiling.
    static func niceCeiling(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let e = pow(10, floor(log10(v)))
        for m in [1, 2, 2.5, 5, 10] where m * e >= v { return m * e }
        return 10 * e
    }
}

/// Soft pulsing dot used as a "measuring now" indicator instead of a spinner.
struct PulsingDot: View {
    var color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            ZStack {
                Circle().fill(color.opacity(0.35 * (1 - phase))).frame(width: 8 + 12 * phase, height: 8 + 12 * phase)
                Circle().fill(color).frame(width: 8, height: 8)
            }
            .frame(width: 20, height: 20)
        }
    }
}
