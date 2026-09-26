import SwiftUI
import ChaiNetCore

/// Real-time throughput chart redrawn every display frame (up to 120 Hz on ProMotion).
///
/// Stability rules (so drawn data never "shakes"):
///
///     bins    fixed, time-aligned buckets of `binSeconds` (0.5 s, doubling for long tests);
///             a completed bucket = bytes × 8 / duration and never changes afterwards
///     head    the eased live readout at the interpolated current time (the only moving point)
///     y-axis  niceCeiling(max(P90 of completed buckets × 1.25, head × 1.15)) eased over ~0.3 s —
///             a single start-up burst can't pin the axis at 1–2 Gbps; values above it are clipped
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
    /// Current readout (Mbps) for the head at a given frame time.
    var head: (Date) -> Double? = { _ in nil }

    @State private var scale = LiveScale()

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { g, size in
                draw(in: &g, size: size, now: context.date)
            }
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

    private func draw(in g: inout GraphicsContext, size: CGSize, now: Date) {
        let leftPad: CGFloat = 4, rightPad: CGFloat = 44, topPad: CGFloat = 10, bottomPad: CGFloat = 18
        let plot = CGRect(x: leftPad, y: topPad, width: size.width - leftPad - rightPad, height: size.height - topPad - bottomPad)

        // Current time between the last two samples (the head moves smoothly, data doesn't).
        var tNow = samples.last?.offset ?? 0
        if samples.count >= 2, let at = lastSampleAt {
            let prev = samples[samples.count - 2].offset, last = samples[samples.count - 1].offset
            tNow = prev + (last - prev) * min(1, max(0, now.timeIntervalSince(at) / max(last - prev, 0.05)))
        }
        let b = Self.binSeconds(duration: max(tNow, 1), width: plot.width, minimum: minimumBinSeconds)
        let bins = Self.bins(samples, binSeconds: b).filter { $0.t <= tNow + 1e-6 }
        let headMbps = head(now)

        // Robust range: typical speed, not the single highest burst.
        let sorted = bins.map(\.mbps).sorted()
        let typical = sorted.isEmpty ? 0 : (sorted.count >= 3 ? Percentile.value(0.9, sorted: sorted)! : sorted.last!)
        let robustMbps = max(typical * 1.25, (headMbps ?? 0) * 1.15)
        let resolved = SpeedFormatter.resolve(unit, mbps: max(robustMbps, 0.001))
        let k = resolved.perMbps
        let yMax = scale.step(toward: LiveScale.niceCeiling(max(robustMbps * k, 0.1)), now: now)
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
            let curve = Self.smoothPath(xy)
            if style == .area {
                var fill = curve
                fill.addLine(to: CGPoint(x: xy.last!.x, y: plot.maxY))
                fill.addLine(to: CGPoint(x: xy.first!.x, y: plot.maxY))
                fill.closeSubpath()
                g.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.40), color.opacity(0.02)]),
                                                   startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            }
            g.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.stroke(curve, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            g.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }

        if let avg = averageMbps, avg > 0 {
            let y = position(0, avg).y
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            g.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            g.draw(Text("平均").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX + 2, y: y - 2), anchor: .bottomLeading)
        }

        if let tip = xy.last {
            let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            let halo = 5 + 9 * phase
            g.fill(Path(ellipseIn: CGRect(x: tip.x - halo, y: tip.y - halo, width: halo * 2, height: halo * 2)),
                   with: .color(color.opacity(0.35 * (1 - phase))))
            g.fill(Path(ellipseIn: CGRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8)), with: .color(color))
            g.fill(Path(ellipseIn: CGRect(x: tip.x - 1.8, y: tip.y - 1.8, width: 3.6, height: 3.6)), with: .color(.white))
        }
    }

    /// Catmull-Rom spline (tension 1/6) through the points, clamped to the plot baseline.
    static func smoothPath(_ p: [CGPoint]) -> Path {
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 2 else {
            p.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        let floorY = p.map(\.y).max() ?? first.y
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let t: CGFloat = 1 / 6
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * t, y: min(floorY, p1.y + (p2.y - p0.y) * t))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * t, y: min(floorY, p2.y - (p3.y - p1.y) * t))
            path.addCurve(to: p2, control1: c1, control2: c2)
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
