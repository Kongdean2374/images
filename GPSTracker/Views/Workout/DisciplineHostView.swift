import SwiftUI

/// 運動項目的統一入口：自動判斷要開 GPS 版還是免定位版，
/// 並提供該項目的獨立設定頁（右上角齒輪）。
struct DisciplineHostView: View {
    let discipline: Discipline

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var location = LocationManager.shared

    @State private var showSettings = false
    @State private var showSwitchToast = false

    private var preference: RecordingPreference { settings.preference(for: discipline.id) }

    private var usingGPS: Bool {
        DisciplineCatalog.resolve(discipline,
                                  preference: preference,
                                  locationAvailable: location.canRecordGPS)
    }

    /// 使用者指定要 GPS，但沒有定位權限 → 自動退回免定位版並提示
    private var fellBackToIndoor: Bool {
        discipline.isDual && preference == .gps && !location.canRecordGPS
    }

    var body: some View {
        ZStack {
            if usingGPS, let gpsType = discipline.gpsType {
                GPSTrackingView(type: gpsType,
                                sport: discipline.gpsSport,
                                discipline: discipline,
                                onSettings: { showSettings = true })
                .id("gps-\(discipline.id)")
            } else if let indoorType = discipline.indoorType {
                indoorView(indoorType)
                    .id("indoor-\(discipline.id)")
            }

            if showSwitchToast { toast }
        }
        .sheet(isPresented: $showSettings) {
            WorkoutSettingsView(discipline: discipline)
                .environmentObject(settings)
        }
        .onAppear {
            if fellBackToIndoor || (discipline.isDual && preference == .auto && !location.canRecordGPS) {
                flashToast()
            }
        }
    }

    // MARK: 免定位版分派

    @ViewBuilder
    private func indoorView(_ type: WorkoutType) -> some View {
        switch type {
        case .walk, .run, .treadmill, .stairs, .ruck:
            StepWorkoutView(initialMode: type,
                            discipline: discipline,
                            onSettings: { showSettings = true })
        case .lapCounter:
            LapCounterView(onSettings: { showSettings = true })
        case .shuttleRun:
            LapCounterView(mode: .shuttleRun, onSettings: { showSettings = true })
        case .indoorInterval:
            IntervalTimerView(onSettings: { showSettings = true })
        case .indoorReps:
            IndoorRepsView(onSettings: { showSettings = true })
        case .plank:
            PlankTimerView(onSettings: { showSettings = true })
        case .fitnessTest:
            FitnessTestView()
        case .manualEntry:
            ManualEntryView()
        case .timedActivity:
            if let sport = discipline.indoorSport ?? discipline.gpsSport {
                TimedActivityView(sport: sport, onSettings: { showSettings = true })
            } else {
                ManualEntryView()
            }
        default:
            StepWorkoutView(initialMode: .walk,
                            discipline: discipline,
                            onSettings: { showSettings = true })
        }
    }

    // MARK: 自動切換提示

    private var toast: some View {
        VStack {
            Spacer()
            HStack(spacing: 9) {
                Image(systemName: "location.slash.fill")
                    .foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("沒有定位，已自動切換成免定位版")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("右上角齒輪可查看與調整記錄方式")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(.bottom, 150)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private func flashToast() {
        withAnimation(.spring(response: 0.4)) { showSwitchToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            withAnimation(.easeOut(duration: 0.3)) { showSwitchToast = false }
        }
    }
}
