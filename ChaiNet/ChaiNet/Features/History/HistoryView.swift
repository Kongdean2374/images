import SwiftUI
import ChaiNetCore

struct HistoryView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case list = "紀錄", dashboard = "儀表板", compare = "比較", map = "地圖"
        var id: String { rawValue }
    }

    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var mode: Mode = .list
    @State private var range: HistoryRange = .days7
    @State private var network: NetworkClass?
    @State private var all: [TestResult] = []
    @State private var anomalous: Set<UUID> = []
    @State private var exportFile: ExportFile?

    private var filtered: [TestResult] { HistoryAggregator.filter(all, range: range, network: network) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker("模式", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    Picker("範圍", selection: $range) { ForEach(HistoryRange.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented)
                    Menu {
                        Button("全部網路") { network = nil }
                        ForEach(NetworkClass.allCases.filter { $0 != .unknown }, id: \.self) { n in Button(n.displayName) { network = n } }
                    } label: {
                        Label(network?.displayName ?? "全部", systemImage: "line.3.horizontal.decrease.circle").font(.caption)
                    }
                }
            }
            .padding(.horizontal).padding(.top, 8)

            switch mode {
            case .list: list
            case .dashboard: ScrollView { HistoryDashboardView(results: filtered).padding() }
            case .compare: CompareView(results: filtered)
            case .map: HistoryMapView(results: filtered)
            }
        }
        .screenBackground()
        .navigationTitle("歷史")
        .toolbar {
            Menu {
                ForEach(ExportFormatSetting.allCases) { f in
                    Button("匯出 \(f.displayName)") {
                        if let url = try? ExportService.exportResults(filtered, format: f, includeLocation: settings.settings.includeLocationInExports) {
                            exportFile = ExportFile(url: url)
                        }
                    }
                }
            } label: { Image(systemName: "square.and.arrow.up") }
            .disabled(filtered.isEmpty)
        }
        .sheet(item: $exportFile) { file in
            VStack(spacing: 16) {
                Text(file.url.lastPathComponent).font(.footnote.monospaced())
                ShareLink(item: file.url) { Label("分享 / 儲存檔案", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
            }
            .presentationDetents([.height(160)])
        }
        .task(id: app.history.changeToken) { reload() }
    }

    private var list: some View {
        List {
            if filtered.isEmpty {
                EmptyStateView(symbol: "clock", title: "沒有紀錄", message: "此範圍內沒有測試結果。").listRowBackground(Color.clear)
            }
            ForEach(filtered) { r in
                NavigationLink { ResultDetailView(result: r) } label: {
                    HistoryRow(result: r, anomalous: anomalous.contains(r.id))
                }
                .listRowBackground(Theme.surface)
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { filtered[$0].id })
                try? app.history.delete(ids: ids)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func reload() {
        all = app.history.allResults()
        // Anomalies vs this device's own baseline (network × time of day × area).
        let store = BaselineEngine().build(from: all)
        let detector = AnomalyDetector()
        anomalous = Set(all.prefix(200).filter { !detector.compare($0, store: store).anomalies.isEmpty }.map(\.id))
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct HistoryRow: View {
    let result: TestResult
    var anomalous = false
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let m = result.metrics
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.kind.displayName).font(.subheadline.weight(.semibold))
                    if anomalous { Badge(text: "異常", color: Theme.warning) }
                    if result.wasCancelled { Badge(text: "中止", color: Theme.textSecondary) }
                }
                Text("\(Format.date(result.date)) · \(NetworkClass(snapshot: result.network).displayName)")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    if let d = m.downloadMbps { Label(Format.speed(d, settings: settings.settings), systemImage: "arrow.down").foregroundStyle(Theme.download) }
                    if let u = m.uploadMbps { Label(Format.speed(u, settings: settings.settings), systemImage: "arrow.up").foregroundStyle(Theme.upload) }
                    if let p = m.idleLatencyMs { Label(Format.ms(p), systemImage: "dot.radiowaves.left.and.right").foregroundStyle(Theme.latency) }
                }
                .font(.caption2.monospacedDigit())
            }
            Spacer()
            if let score = result.scores.overall {
                Text("\(score)").font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(Theme.scoreColor(score))
            }
        }
        .padding(.vertical, 4)
    }
}
