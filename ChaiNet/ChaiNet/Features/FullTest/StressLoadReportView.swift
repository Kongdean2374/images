import SwiftUI
import ChaiNetCore

/// v3.0 stress-load results (ramp, sustained, full duplex, burst, multi-destination, recovery,
/// environment). Shared by the Extreme Stress Test and the toolbox stress tools. Values that were
/// not measured show「—」; nothing is estimated or simulated.
struct StressLoadSummaryCard: View {
    let report: StressLoadReport
    let standardDownloadMbps: Double?
    let standardUploadMbps: Double?

    var body: some View {
        let sentence = report.summarySentence(standardDownloadMbps: standardDownloadMbps, standardUploadMbps: standardUploadMbps)
        if !sentence.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("總結", systemImage: "text.quote").font(.headline)
                Text(sentence).font(.subheadline).foregroundStyle(Theme.textPrimary)
                Text("負載延遲為同一固定對照探測的量測值；佇列發生在哪一段（本機、Wi-Fi、基地台、ISP）無法由此判定。")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }
}

/// Tiles for the stress-load part of a result.
struct StressLoadTiles: View {
    let report: StressLoadReport
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let sc = report.scores
        if report.maxStressDownloadMbps != nil || report.maxStressUploadMbps != nil {
            let dl = Format.speedParts(report.maxStressDownloadMbps, settings: settings.settings)
            let ul = Format.speedParts(report.maxStressUploadMbps, settings: settings.settings)
            MetricTile(title: "最大壓力下載", value: dl.value, unit: dl.unit, caption: "壓力階段最高平均（不作為正常網速）", symbol: "arrow.down.to.line", tint: Theme.download)
            MetricTile(title: "最大壓力上傳", value: ul.value, unit: ul.unit, caption: "壓力階段最高平均（不作為正常網速）", symbol: "arrow.up.to.line", tint: Theme.upload)
        }
        if let ramp = report.streamRamp {
            MetricTile(title: "飽和連線數", value: ramp.saturationStreamCount.map(String.init) ?? "未飽和", unit: ramp.saturationDetected ? "條" : "",
                       caption: ramp.saturationDetected ? "建議 \(ramp.recommendedStreams) 條 · 效率 \(Format.number(ramp.scalingEfficiency0_100, digits: 0))%"
                                                        : "到 \(ramp.maxObservedStreamCount) 條仍在成長",
                       symbol: "arrow.up.right.and.arrow.down.left", tint: Theme.accent)
        }
        if report.sustainedDownload != nil || report.sustainedUpload != nil {
            let d = report.sustainedDownload?.throughput?.degradationPercent
            let u = report.sustainedUpload?.throughput?.degradationPercent
            let worst = [d, u].compactMap { $0 }.max()
            MetricTile(title: "持續負載衰退", value: Format.number(worst, digits: 0), unit: "%",
                       caption: "↓ \(Format.number(d, digits: 0))% · ↑ \(Format.number(u, digits: 0))%（結尾 vs 開頭）",
                       symbol: "hourglass", tint: (worst ?? 0) >= 15 ? Theme.warning : Theme.accent)
        }
        if let fd = report.fullDuplex {
            MetricTile(title: "全雙工延遲", value: Format.number(fd.latency?.inflationMs, digits: 0), unit: "ms",
                       caption: "↓ 降 \(Format.number(fd.downloadDegradationPercent, digits: 0))% · ↑ 降 \(Format.number(fd.uploadDegradationPercent, digits: 0))%",
                       symbol: "arrow.up.arrow.down", tint: (fd.latency?.inflationMs ?? 0) >= 80 ? Theme.critical : Theme.latency)
        }
        if let b = report.burst {
            MetricTile(title: "突發恢復", value: Format.number(b.medianRecoveryTimeMs, digits: 0), unit: "ms",
                       caption: "\(b.cycles.count) 次 · 最差 \(Format.ms(b.worstRecoveryTimeMs))\(b.unrecoveredCycles > 0 ? " · \(b.unrecoveredCycles) 次未恢復" : "")",
                       symbol: "bolt.horizontal", tint: Theme.warning)
        }
        if let m = report.multiDestination {
            let p = Format.speedParts(m.aggregateMbps, settings: settings.settings)
            MetricTile(title: "多目的地總和", value: p.value, unit: p.unit,
                       caption: m.singleDestinationLimitationPossible ? "高於單一目的地：可能有單點限制" : "\(m.destinations.count) 個目的地同時下載",
                       symbol: "point.3.connected.trianglepath.dotted", tint: Theme.accent)
        }
        if let f = report.finalRecovery {
            MetricTile(title: "負載後恢復", value: f.complete ? Format.number(f.recoveryTime10PercentMs, digits: 0) : "未完成",
                       unit: f.complete ? "ms" : "",
                       caption: f.complete ? "回到基準 ±10%（±20%：\(Format.ms(f.recoveryTime20PercentMs))）" : "\(Format.number(f.plannedSeconds, digits: 0)) 秒內未回到基準",
                       symbol: "arrow.uturn.backward.circle", tint: f.complete ? Theme.good : Theme.warning)
        }
        if let s = sc.stressEndurance {
            MetricTile(title: "壓力耐受", value: String(s), unit: "/100",
                       caption: [sc.fullDuplex.map { "全雙工 \($0)" }, sc.burstResilience.map { "突發 \($0)" }, sc.recovery.map { "恢復 \($0)" }]
                           .compactMap { $0 }.joined(separator: " · "),
                       symbol: "flame", tint: Theme.critical)
        }
    }
}

/// Technical sections for the stress-load report.
struct StressLoadTechnicalSections: View {
    let report: StressLoadReport
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 16) {
            if let ramp = report.streamRamp {
                section("連線數階梯（\(ramp.method)）") {
                    ForEach(ramp.stages, id: \.streamCount) { st in
                        KeyValueRow(key: "\(st.streamCount) 條",
                                    value: "\(mbps(st.throughput.averageMbps))" + (st.gainPercent.map { " · 增益 \(Format.number($0, digits: 1))%" } ?? "")
                                        + (st.latency?.medianMs.map { " · 延遲 \(Format.ms($0))" } ?? ""))
                    }
                    KeyValueRow(key: "飽和點", value: ramp.saturationDetected ? "\(ramp.saturationStreamCount ?? 0) 條 · \(mbps(ramp.saturationThroughputMbps))" : "未偵測到（仍在成長）")
                    KeyValueRow(key: "最佳 / 最多", value: "\(ramp.optimalStreamCount.map(String.init) ?? Format.dash) / \(ramp.maxObservedStreamCount) 條")
                    KeyValueRow(key: "邊際增益", value: Format.percent(ramp.marginalGainPercent))
                    KeyValueRow(key: "每條連線效率", value: mbps(ramp.connectionEfficiencyMbpsPerStream))
                    note("連續兩級增益小於 3%，或速度下降，即視為飽和；最大連線數不等於最佳連線數。")
                }
            }
            ForEach([report.sustainedDownload, report.sustainedUpload].compactMap { $0 }, id: \.direction) { s in
                section("持續\(s.direction == .download ? "下載" : "上傳")（\(Format.number(s.plannedSeconds, digits: 0)) 秒 · \(s.streams) 條）") {
                    load(s.throughput)
                    latency(s.latency)
                    if s.thermalStateStart != nil || s.thermalStateEnd != nil {
                        KeyValueRow(key: "溫度狀態", value: "\(s.thermalStateStart ?? "?") → \(s.thermalStateEnd ?? "?")")
                    }
                    if let e = s.error { KeyValueRow(key: "狀態", value: e, valueColor: Theme.warning) }
                }
            }
            if let fd = report.fullDuplex {
                section("全雙工（↓ \(fd.downloadStreams) 條 + ↑ \(fd.uploadStreams) 條 · \(Format.number(fd.plannedSeconds, digits: 0)) 秒）") {
                    KeyValueRow(key: "下載 單向 → 全雙工", value: "\(mbps(fd.downloadOnlyReferenceMbps)) → \(mbps(fd.download?.averageMbps))")
                    KeyValueRow(key: "上傳 單向 → 全雙工", value: "\(mbps(fd.uploadOnlyReferenceMbps)) → \(mbps(fd.upload?.averageMbps))")
                    KeyValueRow(key: "下載 / 上傳降幅", value: "\(Format.percent(fd.downloadDegradationPercent, digits: 0)) / \(Format.percent(fd.uploadDegradationPercent, digits: 0))")
                    latency(fd.latency)
                    KeyValueRow(key: "佇列位置", value: fd.queueLocation == "unknown" ? "未知（無法由端點量測判定）" : fd.queueLocation)
                }
            }
            if let impact = report.crossLoadImpact {
                section("交叉負載影響") {
                    KeyValueRow(key: "上傳造成下載損失", value: Format.percent(impact.downloadLossDueToUploadPercent))
                    KeyValueRow(key: "下載造成上傳損失", value: Format.percent(impact.uploadLossDueToDownloadPercent))
                    KeyValueRow(key: "延遲：閒置 / 下載 / 上傳 / 全雙工",
                                value: [impact.idleLatencyMs, impact.downloadLoadedLatencyMs, impact.uploadLoadedLatencyMs, impact.fullDuplexLoadedLatencyMs]
                                    .map { Format.number($0, digits: 0) }.joined(separator: " / ") + " ms")
                }
            }
            if let b = report.burst {
                section("突發負載（\(b.cycles.count) 次 · \(b.streams) 條）") {
                    ForEach(b.cycles, id: \.index) { c in
                        KeyValueRow(key: "第 \(c.index) 次",
                                    value: "\(mbps(c.throughputMbps)) · 峰值 \(Format.ms(c.peakLoadedLatencyMs)) · 恢復 \(c.recoveryTimeMs.map { Format.ms($0) } ?? "未恢復")")
                    }
                    KeyValueRow(key: "恢復 中位數 / P95 / 最差", value: "\(Format.ms(b.medianRecoveryTimeMs)) / \(Format.ms(b.p95RecoveryTimeMs)) / \(Format.ms(b.worstRecoveryTimeMs))")
                    KeyValueRow(key: "延遲上升 / 遺失", value: "\(Format.ms(b.latencyInflationMs)) / \(Format.percent(b.lossPercent))")
                    KeyValueRow(key: "突發穩定度", value: Format.number(b.stabilityScore, digits: 0))
                }
            }
            if let m = report.multiDestination {
                section("多目的地同時下載") {
                    ForEach(m.destinations, id: \.nodeID) { d in
                        KeyValueRow(key: "\(d.name)（\(d.method) ×\(d.streamCount)）", value: mbps(d.throughput?.averageMbps))
                    }
                    KeyValueRow(key: "總和 / 單一最佳", value: "\(mbps(m.aggregateMbps)) / \(mbps(m.bestSingleStandardMbps))")
                    latency(m.latency)
                    note(m.methodEquivalent ? "各目的地方法相同。" : "各目的地量測方法不同：只看總和，不比較供應商快慢。")
                }
            }
            if !report.recoveries.isEmpty {
                section("恢復") {
                    ForEach(Array(report.recoveries.enumerated()), id: \.offset) { _, r in
                        KeyValueRow(key: "\(r.kind == "final" ? "最終" : "短")恢復（\(r.afterPhase) 後）",
                                    value: r.complete ? "±10% \(Format.ms(r.recoveryTime10PercentMs)) · ±20% \(Format.ms(r.recoveryTime20PercentMs))" : "未完成（\(Format.number(r.plannedSeconds, digits: 0)) 秒內）",
                                    valueColor: r.complete ? Theme.textPrimary : Theme.warning)
                    }
                    note("恢復時間 = 延遲連續 2 個樣本回到閒置基準 ±10%（或 ±20%）的時間；未回到基準時不填入數值。")
                }
            }
            let sc = report.scores
            section("壓力子分數") {
                KeyValueRow(key: "飽和穩定度", value: Format.score(sc.saturationStability))
                KeyValueRow(key: "全雙工", value: Format.score(sc.fullDuplex))
                KeyValueRow(key: "突發耐受", value: Format.score(sc.burstResilience))
                KeyValueRow(key: "恢復", value: Format.score(sc.recovery))
                KeyValueRow(key: "負載延遲", value: Format.score(sc.loadedLatency))
                KeyValueRow(key: "壓力耐受", value: Format.score(sc.stressEndurance))
            }
            if let env = report.environment, !env.samples.isEmpty {
                section("裝置環境（僅供相關性參考）") {
                    KeyValueRow(key: "溫度狀態 開始 / 最高 / 結束", value: "\(env.thermalStart ?? "?") / \(env.thermalPeak ?? "?") / \(env.thermalEnd ?? "?")")
                    KeyValueRow(key: "電量", value: "\(Format.number(env.batteryStart, digits: 0))% → \(Format.number(env.batteryEnd, digits: 0))%")
                    KeyValueRow(key: "介面 / 無線技術變化", value: "\(env.interfaceChangeOffsets.count) / \(env.radioChangeOffsets.count) 次")
                    note("RSRP / RSRQ / SINR / 頻段 / 基地台 ID：iOS 不提供，標記為 unavailable，不會估算。溫度上升不代表網路因熱降速。")
                }
            }
            if let mon = report.monitor {
                section("連續監測") {
                    KeyValueRow(key: "探測", value: "\(mon.probe.method) · \(mon.probe.target) · 每 \(Format.number(mon.intervalSeconds, digits: 2)) 秒")
                    KeyValueRow(key: "樣本數", value: "\(mon.samples.count)")
                }
            }
        }
    }

    private func mbps(_ v: Double?) -> String { Format.speed(v, settings: settings.settings) }

    @ViewBuilder
    private func load(_ t: LoadStats?) -> some View {
        if let t {
            KeyValueRow(key: "平均 / 中位數", value: "\(mbps(t.averageMbps)) / \(mbps(t.medianMbps))")
            KeyValueRow(key: "P10 / P95 / 峰值", value: "\(mbps(t.p10Mbps)) / \(mbps(t.p95Mbps)) / \(mbps(t.peakMbps))")
            KeyValueRow(key: "開頭 → 結尾", value: "\(mbps(t.initialMbps)) → \(mbps(t.finalMbps))（\(Format.percent(t.degradationPercent, digits: 0)) 衰退）")
            KeyValueRow(key: "資料量", value: Format.bytes(t.bytes))
        } else {
            KeyValueRow(key: "吞吐量", value: Format.dash)
        }
    }

    @ViewBuilder
    private func latency(_ l: LatencyUnderLoad?) -> some View {
        if let l {
            KeyValueRow(key: "負載延遲 中位數 / P95 / P99", value: "\(Format.ms(l.medianMs)) / \(Format.ms(l.p95Ms)) / \(Format.ms(l.p99Ms))")
            KeyValueRow(key: "延遲上升 / 抖動 / 遺失", value: "\(Format.ms(l.inflationMs)) / \(Format.ms(l.jitterMs, digits: 1)) / \(Format.percent(l.lossPercent))")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(Theme.textSecondary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
