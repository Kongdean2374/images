import SwiftUI
import SwiftData
import UIKit

struct AnalyticsView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var goals: [WorkoutGoal]
    @EnvironmentObject private var settings: AppSettings

    @State private var range: TrendRange = .week
    @State private var metric: TrendMetric = .distance
    @State private var selectedRouteKey: String?
    @State private var selectedClusterID: String?
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var isExporting = false

    /// 所有重運算的結果都先算好放這裡。
    ///
    /// 以前這些全是 computed property，SwiftUI 每次重繪 body 就整批重算一遍，
    /// 其中 BestEffortEngine 要對所有軌跡點跑滑動視窗，紀錄一多就明顯卡頓。
    /// 改成只在進場與資料實際變動時算一次。
    private struct Analytics {
        var buckets: [TrendBucket] = []
        var comparableGroups: [String: [WorkoutSession]] = [:]
        var routeClusters: [RouteCluster] = []
        var weatherPoints: [StatsEngine.WeatherPoint] = []
        var racePredictions: [RacePrediction] = []
        var balance = IntensityBalance()
        var loadReport = TrainingLoadReport()
        var integrity = IntegrityReport()
        var cadenceStats: (average: Double, best: Double, samples: Int)?
        var cadenceSeries: [CadencePoint] = []
        var typeShares: [TypeShare] = []
        var hasDurationData = false
        var hasPaceData = false
        var hasIntensityData = false
    }

    @State private var cache = Analytics()
    /// 上次計算時的資料指紋，變了才重算
    @State private var cacheKey = ""

    private var currentKey: String {
        "\(sessions.count)-\(sessions.first?.id.uuidString ?? "")-\(range.rawValue)"
    }

    private func rebuildCacheIfNeeded() {
        guard cacheKey != currentKey else { return }
        cacheKey = currentKey
        guard !sessions.isEmpty else {
            cache = Analytics()
            return
        }

        var next = Analytics()
        next.buckets = StatsEngine.trend(sessions: sessions, range: range)
        next.comparableGroups = StatsEngine.comparableGroups(sessions: sessions)
        next.routeClusters = RouteClusterEngine.cluster(sessions: sessions)
        next.weatherPoints = StatsEngine.weatherCorrelation(sessions: sessions)
        next.racePredictions = RacePredictionEngine.predictions(
            from: BestEffortEngine.evaluate(sessions: sessions))
        next.balance = IntensityBalanceEngine.evaluate(sessions: sessions)
        next.loadReport = TrainingLoadEngine.report(sessions: sessions)
        next.integrity = DataIntegrity.report(sessions: sessions)
        next.cadenceStats = DataIntegrity.cadenceStats(sessions: sessions)
        next.typeShares = StatsEngine.typeDistribution(sessions: sessions)
        next.cadenceSeries = Array(sessions.compactMap { session -> CadencePoint? in
            guard let cadence = session.cadence, cadence > 40, cadence < 250 else { return nil }
            return CadencePoint(date: session.startDate, cadence: cadence)
        }
        .sorted { $0.date < $1.date }
        .suffix(40))
        next.hasDurationData = sessions.contains { $0.duration > 60 }
        next.hasPaceData = sessions.contains { ($0.averagePace ?? 0) > 0 }
        next.hasIntensityData = sessions.contains { ($0.intensityScore ?? 0) > 0 }
        cache = next
    }

    private var buckets: [TrendBucket] { cache.buckets }
    private var comparableGroups: [String: [WorkoutSession]] { cache.comparableGroups }
    private var routeClusters: [RouteCluster] { cache.routeClusters }
    private var weatherPoints: [StatsEngine.WeatherPoint] { cache.weatherPoints }
    private var racePredictions: [RacePrediction] { cache.racePredictions }
    private var hasDurationData: Bool { cache.hasDurationData }
    private var hasPaceData: Bool { cache.hasPaceData }
    private var hasIntensityData: Bool { cache.hasIntensityData }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if sessions.isEmpty {
                    emptyState
                } else {
                    insightsLink
                    trendCard
                    if hasDurationData { trainingLoadCard }
                    if hasPaceData {
                        IntensityBalanceCard(balance: cache.balance)
                    }
                    if !racePredictions.isEmpty {
                        RacePredictionCard(predictions: racePredictions, unit: settings.unit)
                    }
                    goalCard
                    if !routeClusters.isEmpty { autoRouteCard } else if !comparableGroups.isEmpty { comparisonCard }
                    if hasIntensityData { intensityCard }
                    distributionCard
                    if weatherPoints.count >= 2 { weatherCard }
                    cadenceCard
                    integrityCard
                    exportCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .onAppear { rebuildCacheIfNeeded() }
        .onChange(of: sessions.count) { _, _ in rebuildCacheIfNeeded() }
        .onChange(of: range) { _, _ in rebuildCacheIfNeeded() }
        .navigationTitle("圖表分析")
        .sheet(isPresented: $showExport) {
            if let exportURL {
                VStack(spacing: 16) {
                    Text("報表已產生")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(exportURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    ShareLink(item: exportURL) {
                        Label("分享／儲存", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding()
                .presentationDetents([.height(220)])
            }
        }
    }

    // MARK: 區塊


    // MARK: 訓練負荷

    private var loadReport: TrainingLoadReport { cache.loadReport }

    private var trainingLoadCard: some View {
        let report = loadReport
        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    GlossaryHeader(title: "訓練負荷", termID: "trainingLoad")
                    Spacer()
                    Text(report.zone.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(zoneColor(report.zone).opacity(0.22)))
                        .foregroundStyle(zoneColor(report.zone))
                }

                if report.hasEnoughData {
                    TrainingLoadChart(daily: Array(report.daily.suffix(42)), average: report.chronic / 7)
                } else {
                    EmptyStateView(systemImage: "chart.bar.doc.horizontal",
                                   title: "再多幾次就能算出負荷趨勢",
                                   message: "需要近 90 天內至少 5 個有運動的日子。",
                                   tint: Theme.accent,
                                   compact: true)
                    ProgressHint(title: "有運動的天數",
                                 current: report.daily.filter { $0.load > 0 }.count,
                                 target: 5)
                }

                HStack {
                    StatPill(title: "7 天負荷", value: String(format: "%.0f", report.acute), tint: Theme.accent)
                    StatPill(title: "28 天週均", value: String(format: "%.0f", report.chronic), tint: Theme.mint)
                    StatPill(title: "急慢性比",
                             value: report.hasEnoughData ? String(format: "%.2f", report.ratio) : "--",
                             tint: zoneColor(report.zone),
                             termID: "acwr")
                }
                HStack {
                    StatPill(title: "體能 CTL", value: String(format: "%.0f", report.ctl),
                             tint: Theme.accent, termID: "ctl")
                    StatPill(title: "疲勞 ATL", value: String(format: "%.0f", report.atl),
                             tint: Theme.accentWarm, termID: "atl")
                    StatPill(title: "狀態 \(report.formText)",
                             value: String(format: "%+.0f", report.tsb),
                             tint: report.tsb >= 0 ? Theme.mint : Theme.amber,
                             termID: "tsb")
                }

                if report.hasEnoughData {
                    HStack(spacing: 6) {
                        Image(systemName: report.weeklyChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                        Text(String(format: "本週較上週 %+.0f%%，近 7 天休息 %d 天",
                                    report.weeklyChange * 100, report.restDays7))
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                    Text(report.advice)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func zoneColor(_ zone: TrainingLoadReport.Zone) -> Color {
        switch zone {
        case .insufficient: return Theme.textSecondary
        case .detraining: return Theme.accent
        case .optimal: return Theme.mint
        case .caution: return Theme.amber
        case .risk: return Theme.accentWarm
        }
    }

    // MARK: 步頻

    @ViewBuilder
    private var cadenceCard: some View {
        if let stats = cache.cadenceStats {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("步頻分析")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    HStack {
                        StatPill(title: "平均步頻", value: String(format: "%.0f", stats.average), tint: Theme.accent)
                        StatPill(title: "最高步頻", value: String(format: "%.0f", stats.best), tint: Theme.mint)
                        StatPill(title: "樣本", value: "\(stats.samples)", tint: Theme.amber)
                    }
                    CadenceTrendChart(points: cadenceSeries)
                    Text("步頻偏低（低於 160）通常代表步幅過大、觸地時間長；用步頻節拍器練習可以逐步改善。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var cadenceSeries: [CadencePoint] { cache.cadenceSeries }

    // MARK: 資料完整性

    private var integrityCard: some View {
        let report = cache.integrity
        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("資料完整性")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(report.grade)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.mint)
                }

                HStack(spacing: 18) {
                    ZStack {
                        RingProgress(progress: report.completeness, lineWidth: 11)
                        Text("\(report.completenessPercent)%")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.total) 筆紀錄")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let first = report.firstDate, let last = report.lastDate {
                            Text("\(Fmt.date(first)) ～ \(Fmt.date(last))")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text("涵蓋 \(report.coverageDays) 天・可校正樣本 \(report.calibrationSamples) 筆")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                ForEach(report.issues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: severityIcon(issue.severity))
                            .font(.caption)
                            .foregroundStyle(severityColor(issue.severity))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(issue.detail)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                NavigationLink {
                    StrideCalibrationView()
                } label: {
                    Label("前往步幅校正中心", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func severityIcon(_ severity: IntegrityIssue.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .problem: return "xmark.octagon"
        }
    }

    private func severityColor(_ severity: IntegrityIssue.Severity) -> Color {
        switch severity {
        case .info: return Theme.textSecondary
        case .warning: return Theme.amber
        case .problem: return Theme.accentWarm
        }
    }

    private var trendCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("歷史趨勢")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Picker("區間", selection: $range) {
                        ForEach(TrendRange.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TrendMetric.allCases) { item in
                            Button {
                                withAnimation(.easeInOut(duration: 0.35)) { metric = item }
                                CueService.shared.impact(.soft)
                            } label: {
                                Text(item.displayName)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(metric == item
                                                               ? item.tint.opacity(0.3)
                                                               : Color.white.opacity(0.07)))
                                    .foregroundStyle(metric == item ? item.tint : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                TrendChartView(buckets: buckets, metric: metric, unit: settings.unit)
                    .transition(.opacity)
                    .id(range)

                HStack {
                    StatPill(title: "區間總里程",
                             value: Fmt.distanceValue(buckets.reduce(0) { $0 + $1.totalDistance }, unit: settings.unit),
                             tint: Theme.accent)
                    StatPill(title: "區間總時間",
                             value: Fmt.duration(buckets.reduce(0) { $0 + $1.totalDuration }),
                             tint: Theme.mint)
                    StatPill(title: "區間次數",
                             value: "\(buckets.reduce(0) { $0 + $1.count })",
                             tint: Theme.amber)
                }
            }
        }
    }

    private var goalCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("目標達成率")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    NavigationLink {
                        GoalSettingsView()
                    } label: {
                        Label("設定", systemImage: "target")
                            .font(.caption)
                    }
                    .foregroundStyle(Theme.accent)
                }

                if goals.isEmpty {
                    Text("尚未設定目標。設定每週或每月的里程、次數或時間目標，這裡會顯示環形進度。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(goals) { goal in
                                goalRing(goal)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func goalRing(_ goal: WorkoutGoal) -> some View {
        let progress = StatsEngine.progress(for: goal, sessions: sessions)
        return VStack(spacing: 8) {
            ZStack {
                RingProgress(progress: progress.fraction, lineWidth: 12)
                VStack(spacing: 2) {
                    Text(String(format: "%.0f%%", progress.fraction * 100))
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: "%.1f/%.0f", progress.current, progress.target))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 104, height: 104)
            Text("\(goal.period.displayName)\(goal.metric.displayName)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var autoRouteCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("同路線比較")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("自動辨識")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.mint.opacity(0.18)))
                        .foregroundStyle(Theme.mint)
                }
                Text("依起點、終點與總距離自動分群，不用自己命名路線。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(routeClusters) { cluster in
                            Button {
                                withAnimation { selectedClusterID = cluster.signature }
                            } label: {
                                VStack(spacing: 3) {
                                    Text(cluster.name)
                                        .font(.caption.weight(.semibold))
                                    Text("\(cluster.count) 次")
                                        .font(.system(size: 10))
                                }
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(activeCluster?.signature == cluster.signature
                                                           ? Theme.accent.opacity(0.3)
                                                           : Color.white.opacity(0.07)))
                                .foregroundStyle(activeCluster?.signature == cluster.signature
                                                 ? Theme.accent : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let cluster = activeCluster {
                    let group = RouteClusterEngine.sessions(in: cluster, from: sessions)
                    RouteComparisonChart(sessions: group, unit: settings.unit)
                    HStack {
                        StatPill(title: "平均距離",
                                 value: Fmt.distance(cluster.averageDistance, unit: settings.unit),
                                 tint: Theme.accent)
                        StatPill(title: "最佳配速",
                                 value: Fmt.pace(cluster.bestPace, unit: settings.unit),
                                 tint: Theme.mint)
                        if let improvement = cluster.improvement {
                            StatPill(title: improvement >= 0 ? "比首次快" : "比首次慢",
                                     value: String(format: "%.1f%%", abs(improvement)),
                                     tint: improvement >= 0 ? Theme.mint : Theme.amber)
                        }
                    }
                    Text("首次 \(Fmt.date(cluster.firstDate))　最近 \(Fmt.date(cluster.latestDate))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var activeCluster: RouteCluster? {
        if let selectedClusterID,
           let match = routeClusters.first(where: { $0.signature == selectedClusterID }) {
            return match
        }
        return routeClusters.first
    }

    private var comparisonCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("同路線歷史比較")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                let keys = comparableGroups.keys.sorted()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(keys, id: \.self) { key in
                            Button {
                                withAnimation { selectedRouteKey = key }
                            } label: {
                                Text(key)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill((selectedRouteKey ?? keys.first) == key
                                                               ? Theme.accent.opacity(0.3)
                                                               : Color.white.opacity(0.07)))
                                    .foregroundStyle((selectedRouteKey ?? keys.first) == key
                                                     ? Theme.accent : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let key = selectedRouteKey ?? keys.first,
                   let group = comparableGroups[key] {
                    RouteComparisonChart(sessions: group, unit: settings.unit)
                    Text("共 \(group.count) 次紀錄")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var intensityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlossaryHeader(title: "心肺負荷估算", termID: "intensityScore")
                Text("以配速、海拔變化與時長推估相對強度，不需要心率裝置。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                IntensityHeatmap(sessions: sessions)
            }
        }
    }

    private var distributionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("運動類型分佈")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                TypeDistributionChart(shares: cache.typeShares)
            }
        }
    }

    private var weatherCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("天氣與表現關聯")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("氣溫 vs 平均配速（僅統計有標記天氣的紀錄）")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                WeatherScatterChart(points: weatherPoints, unit: settings.unit)
            }
        }
    }

    private var exportCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("匯出報表")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("CSV 含所有數據明細；PDF 月報表含圖表快照。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 12) {
                    Button {
                        exportURL = DataExporter.csv(sessions: sessions)
                        showExport = exportURL != nil
                    } label: {
                        Label("CSV", systemImage: "tablecells")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        Task { await exportPDF() }
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Label("PDF 月報表", systemImage: "doc.richtext")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            EmptyStateView(systemImage: "chart.xyaxis.line",
                           title: "還沒有可分析的資料",
                           message: "完成第一次運動，或從健康 App 匯入歷史紀錄。")
            NavigationLink {
                HealthImportView()
            } label: {
                Label("一鍵匯入歷史紀錄", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.top, 50)
    }

    private var insightsLink: some View {
        NavigationLink {
            HistoryInsightsView()
        } label: {
            GlassCard(padding: 14) {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Theme.violet.opacity(0.18))
                        Image(systemName: "chart.pie.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.violet)
                    }
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("歷史總覽")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(sessions.count) 筆紀錄的年度、來源與類型分析")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func exportPDF() async {
        isExporting = true
        defer { isExporting = false }

        var images: [UIImage] = []
        let trend = VStack(alignment: .leading, spacing: 8) {
            Text("歷史趨勢（\(range.displayName)）")
                .font(.headline)
                .foregroundStyle(.white)
            TrendChartView(buckets: buckets, metric: metric, unit: settings.unit)
        }
        .padding(20)
        .background(Theme.bgTop)

        let distribution = VStack(alignment: .leading, spacing: 8) {
            Text("運動類型分佈")
                .font(.headline)
                .foregroundStyle(.white)
            TypeDistributionChart(shares: StatsEngine.typeDistribution(sessions: sessions))
        }
        .padding(20)
        .background(Theme.bgTop)

        if let image = DataExporter.snapshot(of: trend, width: 700, scale: 2) { images.append(image) }
        if let image = DataExporter.snapshot(of: distribution, width: 700, scale: 2) { images.append(image) }

        exportURL = DataExporter.monthlyReport(sessions: sessions, month: Date(), chartImages: images)
        showExport = exportURL != nil
    }
}
