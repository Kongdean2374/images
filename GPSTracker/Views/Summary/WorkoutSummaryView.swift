import SwiftUI
import SwiftData
import MapKit
import UIKit

struct WorkoutSummaryView: View {
    let session: WorkoutSession
    var isNewlyFinished: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var allSessions: [WorkoutSession]

    @State private var selectedSplit: SplitSegment?
    @State private var routeSnapshot: UIImage?
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false
    @State private var celebrationTitles: [String] = []
    @State private var showCelebration = false
    @State private var showPlayback = false
    @State private var showDeleteConfirm = false
    @State private var weatherNote: String = ""
    @State private var temperatureText: String = ""
    @State private var rpe: Int = 0
    @State private var exportURL: URL?
    @State private var showFileShare = false
    @State private var healthMessage: String?
    @State private var isSyncing = false
    @StateObject private var health = HealthKitManager.shared

    private var splits: [SplitSegment] { StatsEngine.splits(for: session) }
    private var points: [RoutePoint] { session.sortedPoints }
    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 18) {
                    headerCard
                    if session.hasRoute { mapCard }
                    metricsCard
                    if !splits.isEmpty {
                        GlassCard {
                            SplitsChartView(splits: splits, selection: $selectedSplit, unit: settings.unit)
                        }
                    }
                    if points.count > 3 {
                        GlassCard { ElevationChartView(points: points) }
                    }
                    if !session.laps.isEmpty { lapsCard }
                    rpeCard
                    weatherCard
                    actionsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }

            if showCelebration {
                CelebrationOverlay(titles: celebrationTitles)
                    .transition(.opacity)
            }
        }
        .screenBackground()
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isNewlyFinished ? "完成" : "關閉") { dismiss() }
            }
        }
        .task {
            weatherNote = session.weatherNote ?? ""
            if let t = session.temperature { temperatureText = String(format: "%.0f", t) }
            rpe = session.rpe ?? 0
            health.refreshAvailability()
            if session.hasRoute {
                routeSnapshot = await MapSnapshotter.snapshot(coordinates: coordinates,
                                                             speeds: points.map { $0.speed })
            }
            if isNewlyFinished {
                let titles = StatsEngine.newRecords(for: session, among: allSessions)
                if !titles.isEmpty {
                    celebrationTitles = titles
                    withAnimation { showCelebration = true }
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    withAnimation { showCelebration = false }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            shareSheet
        }
        .sheet(isPresented: $showFileShare) {
            if let exportURL {
                VStack(spacing: 16) {
                    Text(exportURL.lastPathComponent)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    ShareLink(item: exportURL) {
                        Label("分享／儲存檔案", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding()
                .presentationDetents([.height(200)])
            }
        }
        .fullScreenCover(isPresented: $showPlayback) {
            RoutePlaybackView(session: session)
        }
        .alert("刪除這筆紀錄？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("刪除", role: .destructive) {
                context.delete(session)
                try? context.save()
                dismiss()
            }
        }
    }

    // MARK: 區塊

    private var headerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(session.type.displayName, systemImage: session.type.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.color(for: session.type))
                    Spacer()
                    Text(Fmt.dateTime(session.startDate))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack {
                    MetricTile(title: "距離",
                               value: Fmt.distanceValue(session.totalDistance, unit: settings.unit),
                               unit: Fmt.distanceUnitLabel(settings.unit),
                               tint: Theme.accent, size: 36)
                    MetricTile(title: "時間", value: Fmt.duration(session.duration), size: 36)
                }
                HStack {
                    MetricTile(title: "平均配速",
                               value: Fmt.pace(session.averagePace, unit: settings.unit),
                               unit: Fmt.paceUnitLabel(settings.unit),
                               tint: Theme.mint, size: 26)
                    MetricTile(title: "強度",
                               value: Fmt.decimal(session.intensityScore, digits: 0),
                               unit: IntensityCalculator.label(for: session.intensityScore),
                               tint: Theme.violet, size: 26)
                }
            }
        }
    }

    private var mapCard: some View {
        GlassCard(padding: 0) {
            ZStack(alignment: .bottomTrailing) {
                RouteMapView(coordinates: coordinates,
                             speeds: points.map { $0.speed },
                             highlightRange: selectedSplit?.pointRange,
                             showsMarkers: true,
                             interactive: true)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button {
                    showPlayback = true
                } label: {
                    Label("軌跡回放", systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
    }

    private var metricsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("詳細數據")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 12) {
                    StatPill(title: "爬升", value: Fmt.elevation(session.elevationGain), tint: Theme.amber)
                    StatPill(title: "下降", value: Fmt.elevation(session.elevationLoss), tint: Theme.violet)
                    StatPill(title: "熱量", value: Fmt.decimal(session.calories, digits: 0), tint: Theme.accentWarm)
                    if let steps = session.stepCount {
                        StatPill(title: "步數", value: "\(steps)", tint: Theme.mint)
                    }
                    if let cadence = session.cadence, cadence > 0 {
                        StatPill(title: "步頻", value: Fmt.decimal(cadence, digits: 0), tint: Theme.mint)
                    }
                    if let reps = session.repCount {
                        StatPill(title: "次數", value: "\(reps)", tint: Theme.violet)
                    }
                    if !session.laps.isEmpty {
                        StatPill(title: "圈數", value: "\(session.laps.count)", tint: Theme.amber)
                    }
                    if let floors = session.floorsAscended, floors > 0 {
                        StatPill(title: "爬樓層", value: "\(floors)", tint: Theme.violet)
                    }
                    if let stride = session.strideLength {
                        StatPill(title: "步幅", value: String(format: "%.2fm", stride), tint: Theme.accent)
                    }
                }
                if let source = session.distanceSource {
                    HStack {
                        Text("距離來源")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(source.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                if let walking = session.walkingSeconds, let running = session.runningSeconds {
                    HStack {
                        Text("走跑分段")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("走路 \(Fmt.duration(walking))　跑步 \(Fmt.duration(running))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                if let notes = session.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var lapsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("分圈明細")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                ForEach(session.sortedLaps) { lap in
                    HStack {
                        Text("第 \(lap.lapNumber) 圈")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if let d = lap.distanceOverride {
                            Text(Fmt.distance(d, unit: settings.unit))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text(Fmt.duration(lap.lapDuration))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.accent)
                        if let pace = lap.pace {
                            Text(Fmt.pace(pace, unit: settings.unit))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.mint)
                        }
                    }
                    .padding(.vertical, 3)
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
        }
    }

    private var rpeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("自覺強度 RPE")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if rpe > 0 {
                        Text("\(rpe) / 10　\(rpeLabel)")
                            .font(.subheadline.weight(.semibold))
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.violet)
                    }
                }
                Text("運動後自己評 1～10 分，越主觀越準。會納入訓練負荷統計。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 5) {
                    ForEach(1...10, id: \.self) { value in
                        Button {
                            rpe = value
                            session.rpe = value
                            try? context.save()
                            CueService.shared.impact(.soft)
                        } label: {
                            Text("\(value)")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(rpe == value ? Theme.violet.opacity(0.45) : Color.white.opacity(0.07)))
                                .foregroundStyle(rpe == value ? .white : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var rpeLabel: String {
        switch rpe {
        case 1...2: return "非常輕鬆"
        case 3...4: return "輕鬆"
        case 5...6: return "中等"
        case 7...8: return "吃力"
        case 9...10: return "極限"
        default: return ""
        }
    }

    private var weatherCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("天氣標記（選配）")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("手動記錄天氣與氣溫，之後可在分析頁比較天氣對配速的影響。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    TextField("天氣（晴／陰／雨）", text: $weatherNote)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                    TextField("氣溫 °C", text: $temperatureText)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.plain)
                        .frame(width: 96)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                }
                Button("儲存天氣標記") {
                    session.weatherNote = weatherNote.isEmpty ? nil : weatherNote
                    session.temperature = Double(temperatureText)
                    try? context.save()
                    CueService.shared.notify(.success)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 12) {
            Button {
                Task { await prepareShareCard() }
            } label: {
                Label("產生戰績卡片", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())

            healthCard
            exportCard

            Button {
                showDeleteConfirm = true
            } label: {
                Label("刪除紀錄", systemImage: "trash")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var healthCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("健康 App", systemImage: "heart.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if session.healthKitSynced {
                        Label("已同步", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.mint)
                    }
                }
                Text(health.isReady
                     ? "寫入後，健康 App 與其他讀取健康資料的 App 都能看到這次運動（含 GPS 路線）。"
                     : health.availability.displayName)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if let healthMessage {
                    Text(healthMessage)
                        .font(.caption2)
                        .foregroundStyle(Theme.amber)
                }
                Button {
                    Task { await syncToHealth() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Label(session.healthKitSynced ? "重新寫入健康 App" : "寫入健康 App",
                              systemImage: "arrow.up.heart")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isSyncing)
            }
        }
    }

    private var exportCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("匯出到其他 App")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("GPX 與 TCX 是通用格式，可匯入 Strava、Garmin Connect、Komoot 等。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    if session.hasRoute {
                        Button {
                            exportURL = RouteFileExporter.gpxFile(for: session)
                            showFileShare = exportURL != nil
                        } label: {
                            Label("GPX", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button {
                        exportURL = RouteFileExporter.tcxFile(for: session)
                        showFileShare = exportURL != nil
                    } label: {
                        Label("TCX", systemImage: "doc.text")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        exportURL = DataExporter.routeCSV(session: session)
                        showFileShare = exportURL != nil
                    } label: {
                        Label("CSV", systemImage: "tablecells")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!session.hasRoute)
                }
            }
        }
    }

    @MainActor
    private func syncToHealth() async {
        isSyncing = true
        defer { isSyncing = false }
        healthMessage = nil
        if !health.isReady {
            let granted = await health.requestAuthorization()
            if !granted {
                healthMessage = health.availability == .notEntitled
                    ? "這個安裝版本沒有健康權限（免費 Apple ID 自簽無法啟用），可改用下方 GPX／TCX 匯出。"
                    : "尚未取得健康 App 權限。"
                return
            }
            AppSettings.shared.healthKitEnabled = true
        }
        let uuid = await health.save(WorkoutSnapshot(session: session))
        if let uuid {
            session.healthKitSynced = true
            session.healthKitUUID = uuid
            try? context.save()
            healthMessage = nil
            CueService.shared.notify(.success)
        } else {
            healthMessage = health.lastError ?? "寫入失敗"
        }
    }

    @ViewBuilder
    private var shareSheet: some View {
        NavigationStack {
            ScrollView {
                if let shareImage {
                    VStack(spacing: 18) {
                        Image(uiImage: shareImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(radius: 12)
                        ShareLink(item: Image(uiImage: shareImage),
                                  preview: SharePreview("運動戰績", image: Image(uiImage: shareImage))) {
                            Label("分享 / 儲存圖片", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding()
                } else {
                    ProgressView("產生中…")
                        .padding(50)
                }
            }
            .screenBackground()
            .navigationTitle("戰績卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("關閉") { showShareSheet = false }
                }
            }
        }
    }

    @MainActor
    private func prepareShareCard() async {
        showShareSheet = true
        shareImage = nil
        if session.hasRoute, routeSnapshot == nil {
            routeSnapshot = await MapSnapshotter.snapshot(coordinates: coordinates,
                                                         speeds: points.map { $0.speed })
        }
        let card = ShareCardView(session: session, routeImage: routeSnapshot, unit: settings.unit)
        shareImage = DataExporter.snapshot(of: card, width: 720, scale: 2)
    }
}

/// 歷史紀錄詳情（與摘要頁共用同一份版面）
struct WorkoutDetailView: View {
    let session: WorkoutSession

    var body: some View {
        WorkoutSummaryView(session: session, isNewlyFinished: false)
    }
}
