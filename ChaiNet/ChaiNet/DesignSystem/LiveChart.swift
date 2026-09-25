import SwiftUI
import ChaiNetCore

/// Real-time throughput chart redrawn every display frame (up to 120 Hz on ProMotion).
///
/// Samples arrive every 100 ms; between samples the head of the curve is interpolated from the
/// previous to the newest sample, so the line grows continuously instead of jumping. The y-axis
/// eases toward its new range and the x-axis stretches smoothly with elapsed time.
struct LiveThroughputChart: View {
    let samples: [SpeedSample]
    let lastSampleAt: Date?
    let unit: SpeedUnit
    let color: Color
    var style: ChartStyle = .area
    var averageMbps: Double?
    var height: CGFloat = 180

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

    private func draw(in g: inout GraphicsContext, size: CGSize, now: Date) {
        let resolved = SpeedFormatter.resolve(unit, mbps: samples.map(\.mbps).max() ?? 1)
        let k = resolved.perMbps
        let leftPad: CGFloat = 4, rightPad: CGFloat = 44, topPad: CGFloat = 10, bottomPad: CGFloat = 18
        let plot = CGRect(x: leftPad, y: topPad, width: size.width - leftPad - rightPad, height: size.height - topPad - bottomPad)

        // Points up to an interpolated head between the last two samples.
        var points: [(t: Double, v: Double)] = samples.map { ($0.offset, $0.mbps * k) }
        if points.count >= 2, let last = samples.last, let at = lastSampleAt {
            let prev = points[points.count - 2]
            let head = points[points.count - 1]
            let progress = min(1, max(0, now.timeIntervalSince(at) / max(last.intervalDuration, 0.05)))
            points[points.count - 1] = (prev.t + (head.t - prev.t) * progress, prev.v + (head.v - prev.v) * progress)
        }
        let tMax = max(5, points.last?.t ?? 5)
        let target = LiveScale.niceCeiling((points.map(\.v).max() ?? 0) * 1.15)
        let yMax = scale.step(toward: target, now: now)

        // Grid + y labels.
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

        guard !points.isEmpty else {
            g.draw(Text("等待資料…").font(.footnote).foregroundStyle(.secondary), at: CGPoint(x: plot.midX, y: plot.midY))
            return
        }
        func position(_ p: (t: Double, v: Double)) -> CGPoint {
            CGPoint(x: plot.minX + plot.width * CGFloat(p.t / tMax),
                    y: plot.maxY - plot.height * CGFloat(min(p.v, yMax) / max(yMax, 0.001)))
        }
        let xy = Self.decimate(points.map(position), width: plot.width)

        if style == .bar {
            let w = max(1.5, plot.width / CGFloat(max(xy.count, 1)) * 0.7)
            for p in xy {
                let r = CGRect(x: p.x - w / 2, y: p.y, width: w, height: plot.maxY - p.y)
                g.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .linearGradient(Gradient(colors: [color, color.opacity(0.35)]),
                       startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            }
        } else {
            let curve = Self.smoothPath(xy)
            if style == .area {
                var fill = curve
                fill.addLine(to: CGPoint(x: xy.last!.x, y: plot.maxY))
                fill.addLine(to: CGPoint(x: xy.first!.x, y: plot.maxY))
                fill.closeSubpath()
                g.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.42), color.opacity(0.02)]),
                                                   startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            }
            // Soft glow under the stroke.
            g.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                layer.stroke(curve, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            g.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }

        if let avg = averageMbps, avg > 0 {
            let y = plot.maxY - plot.height * CGFloat(min(avg * k, yMax) / max(yMax, 0.001))
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            g.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            g.draw(Text("平均").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX + 2, y: y - 2), anchor: .bottomLeading)
        }

        // Pulsing head.
        if let head = xy.last {
            let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            let halo = 5 + 9 * phase
            g.fill(Path(ellipseIn: CGRect(x: head.x - halo, y: head.y - halo, width: halo * 2, height: halo * 2)),
                   with: .color(color.opacity(0.35 * (1 - phase))))
            g.fill(Path(ellipseIn: CGRect(x: head.x - 4, y: head.y - 4, width: 8, height: 8)), with: .color(color))
            g.fill(Path(ellipseIn: CGRect(x: head.x - 1.8, y: head.y - 1.8, width: 3.6, height: 3.6)), with: .color(.white))
        }
    }

    /// At most ~1 point per 1.5 px (keeps long tests cheap to draw each frame); the head is kept.
    static func decimate(_ points: [CGPoint], width: CGFloat) -> [CGPoint] {
        let limit = max(2, Int(width / 1.5))
        guard points.count > limit, let last = points.last else { return points }
        let stride = Double(points.count) / Double(limit)
        var out: [CGPoint] = []
        out.reserveCapacity(limit + 1)
        var i = 0.0
        while Int(i) < points.count - 1 {
            out.append(points[Int(i)])
            i += stride
        }
        out.append(last)
        return out
    }

    /// Monotone-ish Catmull-Rom spline through the points (no overshoot below zero).
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
        v >= 100 ? String(format: "%.0f", v) : (v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v))
    }
}

/// Eased y-axis maximum (critically damped, frame-rate independent).
final class LiveScale {
    private var value: Double = 0
    private var last: Date?

    func step(toward target: Double, now: Date) -> Double {
        defer { last = now }
        guard let last, value > 0 else { value = max(target, 1); return value }
        let dt = min(0.1, max(0, now.timeIntervalSince(last)))
        value += (target - value) * (1 - exp(-dt * 7))
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
