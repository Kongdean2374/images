import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var location = LocationManager.shared
    @StateObject private var dailyActivity = DailyActivityProvider()
    @StateObject private var health = HealthKitManager.shared

    @State private var activeMode: WorkoutType?
    @State private var showImport = false
    @StateObject private var intentRouter = PendingIntentRouter.shared

    private let gpsModes: [WorkoutType] = [.gpsRun, .gpsHike]
    private let noGPSModes: [WorkoutType] = [.walk, .run, .treadmill, .stairs, .ruck,
                                             .lapCounter, .shuttleRun, .indoorInterval,
                                             .indoorReps, .plank, .fitnessTest, .manualEntry]

    private var pinned: [WorkoutType] {
        (gpsModes + noGPSModes).filter { settings.isPinned($0) }
    }

    private func visible(_ modes: [WorkoutType]) -> [WorkoutType] {
        modes.filter { !settings.isHidden($0) && !settings.isPinned($0) }
    }

    private func subtitle(for type: WorkoutType) -> String {
        switch type {
        case .gpsRun: return "即時軌跡・3D 鏡頭"
        case .gpsHike: return "海拔與爬升"
        case .walk: return "計步・步頻・樓層"
        case .run: return "步幅換算距離"
        case .treadmill: return "可用實際距離校正"
        case .stairs: return "樓層與垂直爬升"
        case .ruck: return "負重計入熱量估算"
        case .lapCounter: return "固定圈距計圈"
        case .shuttleRun: return "碰線計趟・短距衝刺"
        case .indoorInterval: return "自訂課表・語音提示"
        case .indoorReps: return "自動計次・循環組"
        case .plank: return "撐體計時・穩定度偵測"
        case .fitnessTest: return "四項測驗自動評等"
        case .manualEntry: return "事後補登"
        }
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
                    section("釘選", subtitle: "長按任一模式可釘選或隱藏") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(pinned, id: \.self) { mode in
                                modeTile(mode, subtitle: subtitle(for: mode))
                            }
                        }
                    }
                }

                if !visible(gpsModes).isEmpty {
                    section("需要定位", subtitle: "戶外路跑與健行") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visible(gpsModes), id: \.self) { mode in
                                modeTile(mode, subtitle: subtitle(for: mode))
                            }
                        }
                    }
                }

                if !visible(noGPSModes).isEmpty {
                    section("無定位模式", subtitle: "營區、室內、地下室都能用") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visible(noGPSModes), id: \.self) { mode in
                                modeTile(mode, subtitle: subtitle(for: mode))
                            }
                        }
                    }
                }

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
        .fullScreenCover(item: $activeMode) { mode in
            switch mode {
            case .gpsRun, .gpsHike:
                GPSTrackingView(type: mode)
            case .walk, .run, .treadmill:
                StepWorkoutView(initialMode: mode)
            case .lapCounter:
                LapCounterView()
            case .shuttleRun:
                LapCounterView(mode: .shuttleRun)
            case .ruck:
                StepWorkoutView(initialMode: .ruck)
            case .indoorInterval:
                IntervalTimerView()
            case .indoorReps:
                IndoorRepsView()
            case .plank:
                PlankTimerView()
            case .stairs:
                StepWorkoutView(initialMode: .stairs)
            case .fitnessTest:
                FitnessTestView()
            case .manualEntry:
                ManualEntryView()
            }
        }
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
                        Text("選一個模式開始今天的訓練")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if dailyActivity.isAvailable {
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
                        Text("GPS 模式不可用，其餘八種模式全部照常運作。")
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

    private func modeTile(_ type: WorkoutType, subtitle: String) -> some View {
        Button {
            CueService.shared.impact(.soft)
            activeMode = type
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Theme.color(for: type).opacity(0.18))
                    Image(systemName: type.systemImage)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Theme.color(for: type))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(settings.isPinned(type) ? Theme.accent.opacity(0.5) : Theme.cardStroke,
                                    lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(type.displayName)，\(subtitle)")
        .accessibilityHint("點兩下開始，長按可釘選或隱藏")
        .contextMenu {
            Button {
                settings.togglePinned(type)
            } label: {
                Label(settings.isPinned(type) ? "取消釘選" : "釘選到最上面",
                      systemImage: settings.isPinned(type) ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                settings.toggleHidden(type)
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
