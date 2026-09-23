import SwiftUI
import ChaiNetCore
import ChaiNetEngines

/// Live progress: phase stepper, current speed with average / peak, and a real-time chart.
struct LiveRunView: View {
    let vm: RunViewModel
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 14) {
            PhaseStrip(current: vm.phase, completed: vm.completedPhases, planned: plannedPhases)
            if let direction = vm.activeDirection ?? lastDirection {
                ThroughputLivePanel(vm: vm, direction: direction)
            } else if vm.phase == .idleLatency || vm.phase == .packetLoss || vm.phase == .monitoring {
                LatencyLivePanel(samples: vm.latencySamples[vm.phase ?? .idleLatency] ?? [], title: vm.phase?.displayName ?? "")
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(vm.phase?.displayName ?? "準備中").foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .cardStyle()
            }
            if let server = vm.server {
                Label("\(server.name) · \(server.location)", systemImage: "server.rack")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var lastDirection: TransferDirection? {
        if vm.phase == .upload { return .upload }
        return nil
    }

    private var plannedPhases: [TestPhase] {
        guard let items = vm.configuration?.items else { return [] }
        var phases: [TestPhase] = []
        if !items.isDisjoint(with: [.ping, .jitter, .download, .upload, .bufferbloat]) { phases.append(.idleLatency) }
        if !items.isDisjoint(with: [.packetLoss, .burstLoss, .latencySpikes, .jitter]) { phases.append(.packetLoss) }
        if items.contains(.download) || items.contains(.bufferbloat) { phases.append(.download) }
        if items.contains(.upload) || items.contains(.bufferbloat) { phases.append(.upload) }
        if items.contains(.continuousPing) || items.contains(.dropMonitor) { phases.append(.monitoring) }
        if items.contains(.dns) { phases.append(.dns) }
        if !items.isDisjoint(with: [.http, .tls, .quic]) { phases.append(.protocols) }
        if items.contains(.ipFamilies) { phases.append(.ipFamilies) }
        if items.contains(.crossValidation) { phases.append(.crossValidation) }
        if items.contains(.interfaceCompare) { phases.append(.interfaceCompare) }
        if items.contains(.mtu) { phases.append(.mtu) }
        if items.contains(.traceroute) { phases.append(.traceroute) }
        return phases
    }
}

private struct PhaseStrip: View {
    let current: TestPhase?
    let completed: [TestPhase]
    let planned: [TestPhase]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(planned, id: \.self) { phase in
                    let done = completed.contains(phase)
                    let active = phase == current
                    HStack(spacing: 4) {
                        if done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                        } else if active {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "circle").foregroundStyle(Theme.textSecondary)
                        }
                        Text(phase.displayName)
                    }
                    .font(.caption.weight(active ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(active ? Theme.accent.opacity(0.15) : Theme.surfaceRaised, in: Capsule())
                    .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
                }
            }
        }
        .animation(.snappy, value: current)
    }
}

private struct ThroughputLivePanel: View {
    let vm: RunViewModel
    let direction: TransferDirection
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = settings.settings
        let samples = vm.samples(direction)
        let summary = vm.liveSummary(direction)
        let current = Format.speedParts(vm.currentMbps(direction), settings: s)
        let color = direction == .download ? Theme.download : Theme.upload
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(direction == .download ? "下載" : "上傳", systemImage: direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.headline).foregroundStyle(color)
                Spacer()
                if let n = vm.streams[direction] {
                    Label("\(n) 條連線", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(current.value)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.textPrimary)
                Text(current.unit).font(.title3).foregroundStyle(Theme.textSecondary)
            }
            .animation(.snappy, value: current.value)
            if let secondary = Format.secondarySpeed(vm.currentMbps(direction), settings: s) {
                Text(secondary).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 20) {
                LiveStat(title: "平均", value: Format.speed(summary?.averageMbps, settings: s))
                LiveStat(title: "峰值", value: Format.speed(summary?.peakMbps, settings: s))
                LiveStat(title: "穩定度", value: Format.number(summary?.stability.score, digits: 0))
            }
            ThroughputChart(samples: samples, style: s.chartStyle, unit: s.primarySpeedUnit, color: color, height: 170)
        }
        .cardStyle()
    }
}

private struct LiveStat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.textSecondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct LatencyLivePanel: View {
    let samples: [LatencySample]
    let title: String

    var body: some View {
        let stats = LatencyStatistics.compute(from: samples)
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "dot.radiowaves.left.and.right").font(.headline).foregroundStyle(Theme.latency)
            HStack(spacing: 20) {
                LiveStat(title: "Ping（中位數）", value: Format.ms(stats.rtt?.median))
                LiveStat(title: "抖動", value: Format.ms(stats.rtt?.jitter, digits: 1))
                LiveStat(title: "遺失", value: stats.sent > 0 ? Format.percent(stats.loss.lossPercent) : Format.dash)
            }
            LatencyChart(samples: samples.sorted { $0.sequence < $1.sequence }, height: 140)
        }
        .cardStyle()
    }
}
