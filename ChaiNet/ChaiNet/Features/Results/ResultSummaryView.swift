import SwiftUI
import ChaiNetCore

/// First layer of a result: plain-language, six key numbers, quality scores, top findings.
struct ResultSummaryView: View {
    let result: TestResult
    @Environment(SettingsStore.self) private var settings

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let s = settings.settings
        let m = result.metrics
        VStack(spacing: 14) {
            if result.wasCancelled {
                Label("測試已中止，以下為中止前的部分結果。", systemImage: "pause.circle")
                    .font(.footnote).foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                if m.downloadMbps != nil || result.items.contains(.download) {
                    let p = Format.speedParts(m.downloadMbps, settings: s)
                    MetricTile(title: "下載", value: p.value, unit: p.unit, caption: Format.secondarySpeed(m.downloadMbps, settings: s),
                               symbol: "arrow.down.circle.fill", tint: Theme.download)
                }
                if m.uploadMbps != nil || result.items.contains(.upload) {
                    let p = Format.speedParts(m.uploadMbps, settings: s)
                    MetricTile(title: "上傳", value: p.value, unit: p.unit, caption: Format.secondarySpeed(m.uploadMbps, settings: s),
                               symbol: "arrow.up.circle.fill", tint: Theme.upload)
                }
                if m.idleLatencyMs != nil {
                    MetricTile(title: "Ping", value: Format.number(m.idleLatencyMs, digits: 0), unit: "ms", caption: "中位數",
                               symbol: "dot.radiowaves.left.and.right", tint: Theme.latency)
                    MetricTile(title: "抖動", value: Format.number(m.jitterMs, digits: 1), unit: "ms",
                               symbol: "waveform.path.ecg", tint: Theme.latency)
                }
                if m.lossPercent != nil {
                    MetricTile(title: "封包遺失", value: Format.number(m.lossPercent, digits: 2), unit: "%",
                               caption: m.lossPattern.map(lossPatternText), symbol: "drop.triangle.fill",
                               tint: (m.lossPercent ?? 0) > 2 ? Theme.critical : Theme.good)
                }
                if let grade = result.bufferbloat?.grade {
                    MetricTile(title: "負載延遲", value: grade.rawValue, caption: "Bufferbloat 等級", symbol: "hourglass", tint: Theme.accent)
                }
            }
            if result.scores.overall != nil || result.scores.gaming != nil {
                QualityScoresCard(scores: result.scores)
            }
            if !result.findings.isEmpty {
                FindingsCard(findings: result.findings)
            }
        }
    }

    private func lossPatternText(_ p: LossPattern) -> String {
        switch p {
        case .none: "無遺失"
        case .random: "隨機遺失"
        case .burst: "連續遺失"
        case .mixed: "隨機 + 連續"
        }
    }
}

extension TestResult {
    /// Items that this result covered (for deciding which tiles to show).
    var items: Set<TestItem> {
        var s = Set<TestItem>()
        if download != nil { s.insert(.download) }
        if upload != nil { s.insert(.upload) }
        return s
    }
}

struct QualityScoresCard: View {
    let scores: QualityScores

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("品質分數").font(.headline).foregroundStyle(Theme.textPrimary)
            HStack {
                ScoreRing(score: scores.overall, label: "綜合", size: 58)
                Spacer()
                ScoreRing(score: scores.gaming, label: "遊戲", size: 48)
                Spacer()
                ScoreRing(score: scores.streaming, label: "串流", size: 48)
                Spacer()
                ScoreRing(score: scores.voice, label: "語音", size: 48)
                Spacer()
                ScoreRing(score: scores.upload, label: "上傳", size: 48)
            }
            Text("各場景使用不同權重；資料不足的項目顯示「—」。").font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }
}

struct FindingsCard: View {
    let findings: [DiagnosticFinding]
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快速發現").font(.headline).foregroundStyle(Theme.textPrimary)
            ForEach(showAll ? findings : Array(findings.prefix(3))) { f in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: f.severity.symbol).foregroundStyle(f.severity.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text(f.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                        if showAll { Text("建議：\(f.recommendation)").font(.caption).foregroundStyle(Theme.accent) }
                    }
                }
            }
            if findings.count > 3 || !showAll {
                Button(showAll ? "收合" : "顯示全部與建議") { withAnimation { showAll.toggle() } }
                    .font(.caption.weight(.semibold))
            }
        }
        .cardStyle()
    }
}
