import SwiftUI
import ChaiNetCore

struct MonitorView: View {
    enum Mode { case continuousPing, dropMonitor }
    var mode: Mode = .continuousPing

    @Environment(AppContainer.self) private var app
    @State private var vm: MonitorViewModel?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let vm { content(vm) }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(mode == .continuousPing ? "連續 Ping" : "斷線監測")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if vm == nil {
                vm = MonitorViewModel(engine: app.monitorEngine, settings: app.settings, tasks: app.tasks, recorder: app.recorder,
                                      networkInfo: app.networkInfo)
            }
        }
        .onDisappear { vm?.stop() }
    }

    @ViewBuilder
    private func content(_ vm: MonitorViewModel) -> some View {
        @Bindable var vm = vm
        if !vm.running {
            VStack(alignment: .leading, spacing: 12) {
                Picker("目標", selection: $vm.target) {
                    ForEach([MonitorViewModel.Target.icmp("1.1.1.1"), .icmp("8.8.8.8"), .tcp("www.apple.com"), .server]) { t in
                        Text(t.title).tag(t)
                    }
                }
                Picker("間隔", selection: $vm.interval) {
                    Text("0.5 秒").tag(0.5)
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                }
                .pickerStyle(.segmented)
                Label("iOS 限制：監測只在 App 位於前景時進行，進入背景會自動停止並保存結果。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                PrimaryButton(title: "開始監測", symbol: "play.fill") { vm.start() }
            }
            .cardStyle()
        } else {
            Button(role: .destructive) { vm.stop() } label: { Label("停止並保存", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
        if let error = vm.error { Text(error).font(.footnote).foregroundStyle(Theme.critical) }
        if !vm.samples.isEmpty {
            statusCard(vm)
            VStack(alignment: .leading, spacing: 8) {
                Text("即時延遲（最近 2 分鐘）").font(.headline)
                LatencyChart(samples: vm.recentSamples, height: 180)
            }
            .cardStyle()
            eventsCard(vm)
        }
        if let saved = vm.savedResult {
            NavigationLink { ResultDetailView(result: saved) } label: {
                Label("查看已保存的監測結果", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func statusCard(_ vm: MonitorViewModel) -> some View {
        let stats = vm.statistics
        let last = vm.samples.last?.rttMs
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(vm.inDrop ? Theme.critical : Theme.good).frame(width: 10, height: 10)
                Text(vm.inDrop ? "連線中斷中" : "連線正常").font(.headline)
                Spacer()
                Text("\(vm.samples.count) 個探測").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 0) {
                stat("目前", Format.ms(last))
                stat("中位數", Format.ms(stats.rtt?.median))
                stat("P95", Format.ms(stats.rtt?.p95))
                stat("抖動", Format.ms(stats.rtt?.jitter, digits: 1))
                stat("遺失", Format.percent(stats.loss.lossPercent))
            }
        }
        .cardStyle()
    }

    private func eventsCard(_ vm: MonitorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("事件").font(.headline)
            KeyValueRow(key: "延遲突波", value: "\(vm.spikes.count)")
            KeyValueRow(key: "斷線", value: "\(vm.drops.count)", valueColor: vm.drops.isEmpty ? Theme.textPrimary : Theme.critical)
            KeyValueRow(key: "網路路徑變更", value: "\(vm.pathChanges.count)")
            ForEach(Array(vm.spikes.suffix(5).enumerated()), id: \.offset) { _, s in
                Text("⚡︎ \(Format.number(s.offset, digits: 0))s：\(Format.ms(s.rttMs))（基準 \(Format.ms(s.baselineMs))）").font(.caption)
            }
            ForEach(Array(vm.drops.enumerated()), id: \.offset) { _, d in
                Text("✕ \(Format.number(d.startOffset, digits: 0))s：中斷 \(Format.number(d.duration, digits: 1)) 秒").font(.caption).foregroundStyle(Theme.critical)
            }
            ForEach(Array(vm.pathChanges.enumerated()), id: \.offset) { _, p in
                Text("⇄ \(Format.number(p.offset, digits: 0))s：\(p.interface.displayName)").font(.caption).foregroundStyle(Theme.info)
            }
        }
        .cardStyle()
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.textSecondary)
            Text(value).font(.footnote.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
