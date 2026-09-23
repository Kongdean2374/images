import SwiftUI
import Charts
import ChaiNetCore

/// Compare selected results side by side, or medians per network type (5G vs LTE vs Wi-Fi).
struct CompareView: View {
    let results: [TestResult]
    @Environment(SettingsStore.self) private var settings
    @State private var selected: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                byNetwork
                picker
                if selected.count >= 2 { sideBySide }
            }
            .padding()
        }
    }

    private var byNetwork: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("依網路類型（中位數）").font(.headline)
            let metrics: [BaselineMetric] = [.downloadMbps, .uploadMbps, .latencyMs, .jitterMs, .lossPercent]
            ForEach(metrics, id: \.self) { metric in
                let medians = HistoryAggregator.medianByNetwork(results, metric: metric).sorted { $0.key.rawValue < $1.key.rawValue }
                if !medians.isEmpty {
                    Text("\(metric.displayName)（\(metric.unit)）").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    Chart(medians, id: \.key) { item in
                        BarMark(x: .value(metric.unit, item.value), y: .value("網路", item.key.displayName))
                            .foregroundStyle(by: .value("網路", item.key.displayName))
                            .annotation(position: .trailing) { Text(Format.number(item.value, digits: 1)).font(.caption2) }
                    }
                    .chartLegend(.hidden)
                    .frame(height: CGFloat(medians.count) * 30 + 10)
                }
            }
            if results.isEmpty { Text("沒有資料").font(.footnote).foregroundStyle(Theme.textSecondary) }
        }
        .cardStyle()
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("選擇 2–4 次測試比較").font(.headline)
            ForEach(results.prefix(30)) { r in
                Button {
                    if selected.contains(r.id) { selected.remove(r.id) } else if selected.count < 4 { selected.insert(r.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(r.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                        HistoryRow(result: r)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    private var sideBySide: some View {
        let chosen = results.filter { selected.contains($0.id) }
        let s = settings.settings
        return VStack(alignment: .leading, spacing: 8) {
            Text("並排比較").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    ForEach(chosen) { r in Text(NetworkClass(snapshot: r.network).displayName).font(.caption.weight(.semibold)) }
                }
                row("下載", chosen) { Format.speed($0.metrics.downloadMbps, settings: s) }
                row("上傳", chosen) { Format.speed($0.metrics.uploadMbps, settings: s) }
                row("Ping", chosen) { Format.ms($0.metrics.idleLatencyMs) }
                row("抖動", chosen) { Format.ms($0.metrics.jitterMs, digits: 1) }
                row("遺失", chosen) { Format.percent($0.metrics.lossPercent) }
                row("Bufferbloat", chosen) { $0.bufferbloat?.grade.rawValue ?? Format.dash }
                row("綜合", chosen) { Format.score($0.scores.overall) }
                row("遊戲", chosen) { Format.score($0.scores.gaming) }
                row("時間", chosen) { $0.date.formatted(date: .abbreviated, time: .shortened) }
            }
            .font(.caption.monospacedDigit())
            Text("想做完整的根因比較，請把這些測試加入同一個診斷工作階段。").font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }

    private func row(_ title: String, _ items: [TestResult], _ value: @escaping (TestResult) -> String) -> some View {
        GridRow {
            Text(title).foregroundStyle(Theme.textSecondary)
            ForEach(items) { Text(value($0)) }
        }
    }
}
