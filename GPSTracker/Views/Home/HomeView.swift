import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var location = LocationManager.shared
    @StateObject private var dailyActivity = DailyActivityProvider()
    @StateObject private var health = HealthKitManager.shared

    @State private var activeDiscipline: Discipline?
    @State private var activeMode: WorkoutType?
    @State private var showImport = false
    @State private var showSportPicker = false
    @StateObject private var intentRouter = PendingIntentRouter.shared

    /// 需要定位（或可用定位）的合併項目
    private var gpsDisciplines: [Discipline] { DisciplineCatalog.dualOrGPS }
    /// 完全不需定位的項目
    private var indoorDisciplines: [Discipline] { DisciplineCatalog.indoorOnly }

    private var pinned: [Discipline] {
        DisciplineCatalog.all.filter { settings.isPinned(id: $0.id) }
    }

    private func visible(_ items: [Discipline]) -> [Discipline] {
        items.filter { !settings.isHidden(id: $0.id) && !settings.isPinned(id: $0.id) }
    }

    /// 這個項目進去之後實際會用哪個版本
    private func modeBadge(for discipline: Discipline) -> (text: String, icon: String, warn: Bool) {
        guard discipline.isDual else {
            if discipline.supportsGPS { return ("GPS", "location.fill", false) }
            return ("免定位", "location.slash", false)
        }
        let usingGPS = DisciplineCatalog.resolve(discipline,
                                                 preference: settings.preference(for: discipline.id),
                                                 locationAvailable: location.canRecordGPS)
        if usingGPS { return ("GPS 版", "location.fill", false) }
        return (location.canRecordGPS ? "免定位版" : "自動免定位", "location.slash", !location.canRecordGPS)
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var weekSummary: (distance: Double, duration: TimeInterval, count: Int) {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
        let items = sessions.filter { $0.startDate >= start }
        return (items.reduce(0) { $0 + ($1.totalDistance ?? 0) },
                items.reduce(0) { $0 + $1.duration },
                items.count)
    }

    private var hasImported: Bool { sessions.contains { $0.isImported } }

    private var lastWeekSummary: (distance: Double, duration: TimeInterval, count: Int) {
        let calendar = Calendar.current
        guard let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())),
              let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) else {
            return (0, 0, 0)
        }
        let items = sessions.filter { $0.startDate >= lastWeekStart && $0.startDate < thisWeekStart }
        return (items.reduce(0) { $0 + ($1.totalDistance ?? 0) },
                items.reduce(0) { $0 + $1.duration },
                items.count)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryHeader
                if !sessions.isEmpty {
                    WeeklyRecapCard(thisWeek: weekSummary,
                                    lastWeek: lastWeekSummary,
                                    unit: settings.unit)
                }
                if !hasImported { importPrompt }
                locationBanner

                if !pinned.isEmpty {
                    section("釘選", subtitle: "長按任一項目可釘選或隱藏") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(pinned) { item in
                                disciplineTile(item)
                            }
                        }
                    }
                }

                if !visible(gpsDisciplines).isEmpty {
                    section("移動型運動", subtitle: "有定位走 GPS 版，沒定位自動換免定位版") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visible(gpsDisciplines)) { item in
                                disciplineTile(item)
                            }
                        }
                    }
                }

                if !visible(indoorDisciplines).isEmpty {
                    section("免定位訓練", subtitle: "營區、室內、地下室都能用") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visible(indoorDisciplines)) { item in
                                disciplineTile(item)
                            }
                        }
                    }
                }

                moreSportsTile

                recentSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .task {
            await dailyActivity.load(dayCount: 7)
            health.refreshAvailability()
        }
        .onChange(of: intentRouter.requestedMode) { _, newValue in
            guard let newValue else { return }
            activeMode = newValue
            intentRouter.requestedMode = nil
        }
        .navigationTitle("開始運動")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    DailyActivityView()
                } label: {
                    Image(systemName: "figure.walk.motion")
                }
            }
        }
        .fullScreenCover(item: $activeDiscipline) { item in
            DisciplineHostView(discipline: item)
        }
        .fullScreenCover(item: $activeMode) { mode in
            legacyView(for: mode)
        }
    }

    /// Siri／捷徑或 Widget 直接指定 WorkoutType 時的舊路徑
    @ViewBuilder
    private func legacyView(for mode: WorkoutType) -> some View {
        switch mode {
        case .gpsRun, .gpsHike, .gpsActivity:
            GPSTrackingView(type: mode)
        case .walk, .run, .treadmill, .stairs, .ruck:
            StepWorkoutView(initialMode: mode)
        case .lapCounter:
            LapCounterView()
        case .shuttleRun:
            LapCounterView(mode: .shuttleRun)
        case .indoorInterval:
            IntervalTimerView()
        case .indoorReps:
            IndoorRepsView()
        case .plank:
            PlankTimerView()
        case .fitnessTest:
            FitnessTestView()
        case .manualEntry, .timedActivity:
            ManualEntryView()
        }
    }

    // MARK: 更多運動

    private var moreSportsTile: some View {
        NavigationLink {
            SportPickerView()
        } label: {
            GlassCard(padding: 15) {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Theme.accent.opacity(0.18))
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("更多運動項目")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("單車、球類、重訓、游泳、瑜伽⋯⋯沒有的還能自己新增")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
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

    // MARK: 頂部總覽

    private var summaryHeader: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(greeting)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("選一個項目開始今天的訓練")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if dailyActivity.isAvailable && dailyActivity.hasAnyData {
                        NavigationLink {
                            DailyActivityView()
                        } label: {
                            ZStack {
                                RingProgress(progress: stepProgress, lineWidth: 7)
                                VStack(spacing: 0) {
                                    Text("\(dailyActivity.todaySteps)")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("步")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .frame(width: 66, height: 66)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                HStack(spacing: 10) {
                    StatPill(title: "本週里程", value: Fmt.distanceValue(weekSummary.distance, unit: settings.unit), tint: Theme.accent)
                    StatPill(title: "本週時間", value: Fmt.duration(weekSummary.duration), tint: Theme.mint)
                    StatPill(title: "本週次數", value: "\(weekSummary.count)", tint: Theme.amber)
                }
            }
        }
    }

    private var stepProgress: Double {
        min(1, Double(dailyActivity.todaySteps) / Double(max(1, settings.dailyStepGoal)))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return "早安，準備出發"
        case 11..<17: return "午安，動一下吧"
        case 17..<22: return "晚安，夜跑時間"
        default: return "深夜訓練"
        }
    }

    // MARK: 匯入提示

    private var importPrompt: some View {
        NavigationLink {
            HealthImportView()
        } label: {
            GlassCard(padding: 14) {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Theme.mint.opacity(0.18))
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.mint)
                    }
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("匯入過去的運動紀錄")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("把健康 App 裡的歷史訓練（含其他 App 的）一次帶進來")
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

    @ViewBuilder
    private var locationBanner: some View {
        if location.isDenied {
            GlassCard(padding: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "location.slash.fill")
                        .foregroundStyle(Theme.amber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("定位權限已關閉")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("所有項目已自動切換成免定位版，計步、計時、計圈、計次全部照常運作。")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: 區塊與磚塊

    private func section<Content: View>(_ title: String,
                                        subtitle: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disciplineTile(_ item: Discipline) -> some View {
        let badge = modeBadge(for: item)
        return Button {
            CueService.shared.impact(.soft)
            activeDiscipline = item
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Theme.color(for: item.colorType).opacity(0.18))
                        Image(systemName: item.icon)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.color(for: item.colorType))
                    }
                    .frame(width: 42, height: 42)
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        Image(systemName: badge.icon)
                            .font(.system(size: 8, weight: .bold))
                        Text(badge.text)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(badge.warn ? Theme.amber : Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(settings.isPinned(id: item.id) ? Theme.accent.opacity(0.5) : Theme.cardStroke,
                                    lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.subtitle)，\(badge.text)")
        .accessibilityHint("點兩下開始，長按可釘選或隱藏")
        .contextMenu {
            Button {
                settings.togglePinned(id: item.id)
            } label: {
                Label(settings.isPinned(id: item.id) ? "取消釘選" : "釘選到最上面",
                      systemImage: settings.isPinned(id: item.id) ? "pin.slash" : "pin")
            }
            if item.isDual {
                Button {
                    settings.setPreference(.gps, for: item.id)
                } label: {
                    Label("固定用 GPS 版", systemImage: "location.fill")
                }
                .disabled(!location.canRecordGPS)
                Button {
                    settings.setPreference(.indoor, for: item.id)
                } label: {
                    Label("固定用免定位版", systemImage: "location.slash")
                }
                Button {
                    settings.setPreference(.auto, for: item.id)
                } label: {
                    Label("自動判斷", systemImage: "wand.and.stars")
                }
            }
            Button(role: .destructive) {
                settings.toggleHidden(id: item.id)
            } label: {
                Label("從首頁隱藏", systemImage: "eye.slash")
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !sessions.isEmpty {
            section("最近紀錄", subtitle: "最新 3 筆") {
                VStack(spacing: 10) {
                    ForEach(Array(sessions.prefix(3))) { session in
                        NavigationLink {
                            WorkoutDetailView(session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
