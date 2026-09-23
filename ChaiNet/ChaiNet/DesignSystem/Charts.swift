import SwiftUI
import Charts
import ChaiNetCore

/// Real-time / historical throughput chart (line, area or bar).
struct ThroughputChart: View {
    let samples: [SpeedSample]
    let style: ChartStyle
    let unit: SpeedUnit
    let color: Color
    var height: CGFloat = 180
    var averageMbps: Double?

    private var resolvedUnit: SpeedUnit {
        SpeedFormatter.resolve(unit, mbps: samples.map(\.mbps).max() ?? 1)
    }

    var body: some View {
        let unit = resolvedUnit
        Chart {
            ForEach(samples) { s in
                let y = s.mbps * unit.perMbps
                switch style {
                case .line:
                    LineMark(x: .value("時間", s.offset), y: .value(unit.symbol, y))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(color)
                case .area:
                    AreaMark(x: .value("時間", s.offset), y: .value(unit.symbol, y))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("時間", s.offset), y: .value(unit.symbol, y))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(color)
                case .bar:
                    BarMark(x: .value("時間", s.offset), y: .value(unit.symbol, y), width: .fixed(3))
                        .foregroundStyle(color.gradient)
                }
            }
            if let averageMbps {
                RuleMark(y: .value("平均", averageMbps * unit.perMbps))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("平均").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
            }
        }
        .chartXAxisLabel("秒", alignment: .trailing)
        .chartYAxisLabel(unit.symbol)
        .chartXScale(domain: 0...max(5, samples.last?.offset ?? 5))
        .frame(height: height)
        .animation(.linear(duration: 0.1), value: samples.count)
    }
}

/// RTT over time; lost probes shown as red marks on the baseline.
struct LatencyChart: View {
    let samples: [LatencySample]
    var color: Color = Theme.latency
    var height: CGFloat = 150

    var body: some View {
        Chart {
            ForEach(samples) { s in
                if let rtt = s.rttMs {
                    LineMark(x: .value("序號", s.sequence), y: .value("ms", rtt))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                } else {
                    PointMark(x: .value("序號", s.sequence), y: .value("ms", 0))
                        .foregroundStyle(Theme.critical)
                        .symbol(.cross)
                }
            }
        }
        .chartYAxisLabel("ms")
        .frame(height: height)
    }
}

/// Distribution of RTTs (histogram) — shows long tails that averages hide.
struct LatencyHistogram: View {
    let rtts: [Double]
    var bins = 12

    var body: some View {
        let buckets = Self.histogram(rtts, bins: bins)
        Chart(buckets, id: \.lower) { b in
            BarMark(x: .value("ms", "\(Int(b.lower))"), y: .value("次數", b.count))
                .foregroundStyle(Theme.latency.gradient)
        }
        .chartXAxisLabel("ms")
        .frame(height: 120)
    }

    struct Bucket { var lower: Double; var count: Int }

    static func histogram(_ values: [Double], bins: Int) -> [Bucket] {
        guard let lo = values.min(), let hi = values.max(), hi > lo, bins > 0 else {
            return values.isEmpty ? [] : [Bucket(lower: values[0], count: values.count)]
        }
        let width = (hi - lo) / Double(bins)
        var counts = Array(repeating: 0, count: bins)
        for v in values { counts[min(bins - 1, Int((v - lo) / width))] += 1 }
        return counts.enumerated().map { Bucket(lower: lo + Double($0.offset) * width, count: $0.element) }
    }
}
