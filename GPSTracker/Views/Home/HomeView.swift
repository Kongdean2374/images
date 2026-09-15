import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var location = LocationManager.shared

    @State private var activeMode: WorkoutType?
    @State private var showManualEntry = false

    private var weekSummary: (distance: Double, duration: TimeInterval, count: Int) {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
        let items = sessions.filter { $0.startDate >= start }
        return (items.reduce(0) { $0 + ($1.totalDistance ?? 0) },
                items.reduce(0) { $0 + $1.duration },
                items.count)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                weekCard
                locationBanner
                sectionTitle("需要定位", subtitle: "戶外路跑與健行")
                modeCard(.gpsRun, subtitle: "即時軌跡、配速漸層、3D 鏡頭跟隨")
                modeCard(.gpsHike, subtitle: "海拔爬升與下降記錄")
                sectionTitle("無定位模式", subtitle: "營區、室內、地下室都能用")
                modeCard(.lapCounter, subtitle: "固定圈距手動計圈，純計時計數")
                modeCard(.indoorInterval, subtitle: "衝刺／休息循環，語音與震動提示")
                modeCard(.indoorReps, subtitle: "開合跳、波比跳自動計次")
                modeCard(.manualEntry, subtitle: "事後補登里程與時間")
                recentSection
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("開始運動")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeMode) { mode in
            switch mode {
            case .gpsRun, .gpsHike:
                GPSTrackingView(type: mode)
            case .lapCounter:
                LapCounterView()
            case .indoorInterval:
                IntervalTimerView()
            case .indoorReps:
                IndoorRepsView()
            case .manualEntry:
                ManualEntryView()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("選一個模式，開始今天的訓練")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
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

    private var weekCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("本週累積")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    StatPill(title: "里程（\(Fmt.distanceUnitLabel(settings.unit))）",
                             value: Fmt.distanceValue(weekSummary.distance, unit: settings.unit),
                             tint: Theme.accent)
                    StatPill(title: "時間",
                             value: Fmt.duration(weekSummary.duration),
                             tint: Theme.mint)
                    StatPill(title: "次數",
                             value: "\(weekSummary.count)",
                             tint: Theme.amber)
                }
            }
        }
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
                        Text("GPS 模式不可用，但計圈、間歇、原地運動、手動輸入全部照常運作。")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private func modeCard(_ type: WorkoutType, subtitle: String) -> some View {
        Button {
            CueService.shared.impact(.soft)
            activeMode = type
        } label: {
            GlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.color(for: type).opacity(0.18))
                        Image(systemName: type.systemImage)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.color(for: type))
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(type.displayName)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var recentSection: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("最近紀錄", subtitle: "最新 3 筆")
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
