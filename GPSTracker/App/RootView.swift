import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var startup = AppStartupState.shared
    @State private var didCheckRecovery = false
    @State private var isCheckingRecovery = false
    @State private var recoveryError: String?
    @State private var queuedRecovery: ActiveWorkoutSnapshot?
    @State private var selection = 0
    @State private var didAutoImport = false
    @State private var showOnboarding = false
    @State private var showDatabaseNotice = false
    @State private var pendingRecovery: ActiveWorkoutSnapshot?
    @State private var resumeAfterDismiss: ActiveWorkoutSnapshot?
    @State private var resumingWorkout: ActiveWorkoutSnapshot?

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { HomeView() }
                .tabItem { Label("開始", systemImage: "bolt.horizontal.circle.fill") }
                .tag(0)

            NavigationStack { HistoryListView() }
                .tabItem { Label("紀錄", systemImage: "list.bullet.rectangle.portrait") }
                .tag(1)

            NavigationStack {
                if selection == 2 { AnalyticsView() } else { Color.clear }
            }
                .tabItem { Label("分析", systemImage: "chart.xyaxis.line") }
                .tag(2)

            NavigationStack {
                if selection == 3 { PBDashboardView() } else { Color.clear }
            }
                .tabItem { Label("成就", systemImage: "trophy.fill") }
                .tag(3)

            NavigationStack { SettingsView() }
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(Theme.accent)
        .onAppear {
            if !settings.hasSeenOnboarding { showOnboarding = true }
            if DatabaseHealth.needsAttention { showDatabaseNotice = true }
        }
        .overlay(alignment: .bottom) {
            if isCheckingRecovery {
                ProgressView("正在檢查上次的運動記錄…")
                    .padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 65)
            }
        }
        .onChange(of: showOnboarding) { _, showing in if !showing { presentRecoveryIfPossible() } }
        .onChange(of: showDatabaseNotice) { _, showing in if !showing { presentRecoveryIfPossible() } }
        .alert("運動恢復尚未完成", isPresented: Binding(get: { recoveryError != nil }, set: { if !$0 { recoveryError = nil } })) {
            Button("好") { recoveryError = nil }
        } message: { Text(recoveryError ?? "") }
        .sheet(isPresented: $showDatabaseNotice) {
            DatabaseNoticeView()
        }
        .sheet(item: $pendingRecovery, onDismiss: {
            if let resume = resumeAfterDismiss { resumeAfterDismiss = nil; resumingWorkout = resume }
        }) { snapshot in
            WorkoutRecoveryView(snapshot: snapshot) { resume in
                resumeAfterDismiss = resume
            }
        }
        .fullScreenCover(item: $resumingWorkout) { snapshot in
            GPSTrackingView(type: snapshot.type,
                            sport: snapshot.sport,
                            restoring: snapshot)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            NavigationStack {
                OnboardingView()
            }
        }
        .task(id: startup.isReady) {
            guard startup.isReady, !didCheckRecovery else { return }
            didCheckRecovery = true
            isCheckingRecovery = true
            LiveActivityController.shared.endStaleActivities()
            let recovered = await ActiveWorkoutStore.shared.loadForRecovery()
            guard !Task.isCancelled else { didCheckRecovery = false; isCheckingRecovery = false; return }
            switch recovered {
            case .missing:
                DiagnosticsLog.shared.checkPreviousRun(snapshot: nil)
            case .loaded(let snapshot):
                DiagnosticsLog.shared.checkPreviousRun(snapshot: snapshot)
                if snapshot.isWorthRecovering { queuedRecovery = snapshot; presentRecoveryIfPossible() }
                // Old and short snapshots remain on disk until explicitly discarded or replaced.
            case .unreadable:
                recoveryError = "找到運動暫存，但暫時無法讀取。原始檔案已保留，請勿重裝或清除 App 資料。"
            }
            isCheckingRecovery = false
            guard !didAutoImport, queuedRecovery == nil, pendingRecovery == nil, !showOnboarding, recoveryError == nil,
                  !DatabaseHealth.needsAttention else { return }
            didAutoImport = true
            guard settings.autoImportHealth, HealthKitManager.shared.isReady else { return }
            await HealthKitImporter.shared.importNew(existing: sessions)
            if settings.backgroundUpdates { await HealthBackgroundMonitor.shared.checkDailyGoals() }
        }
    }

    private func presentRecoveryIfPossible() {
        guard !showOnboarding, !showDatabaseNotice, pendingRecovery == nil, let snapshot = queuedRecovery else { return }
        pendingRecovery = snapshot
        queuedRecovery = nil
    }
}
