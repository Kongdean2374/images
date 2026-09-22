import SwiftUI
import SwiftData

/// 上次的運動沒有正常結束時跳出來，讓使用者決定要接續、儲存還是丟棄。
struct WorkoutRecoveryView: View {
    let snapshot: ActiveWorkoutSnapshot
    /// 選擇接續時回傳，由外層開啟記錄畫面
    let onResume: (ActiveWorkoutSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @State private var saved = false

    private var title: String {
        snapshot.sport?.name ?? snapshot.type.displayName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    statsCard
                    actions
                    explainCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .screenBackground()
            .navigationTitle("未完成的紀錄")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.amber.opacity(0.18))
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            }
            .frame(width: 76, height: 76)
            .padding(.top, 14)

            Text("上次的運動沒有正常結束")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("App 被系統關閉或從多工滑掉了，不過進度都有自動存檔，一筆都沒少。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    private var statsCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.color(for: snapshot.type).opacity(0.18))
                        Image(systemName: snapshot.sport?.icon ?? snapshot.type.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.color(for: snapshot.type))
                    }
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(Fmt.dateTime(snapshot.startDate))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack {
                    StatPill(title: "距離",
                             value: Fmt.distanceValue(snapshot.distance, unit: settings.unit),
                             tint: Theme.accent)
                    StatPill(title: "時間",
                             value: Fmt.duration(snapshot.elapsed),
                             tint: Theme.mint)
                    StatPill(title: "軌跡點",
                             value: "\(snapshot.points.count)",
                             tint: Theme.amber)
                }

                Text("最後存檔於 \(Fmt.dateTime(snapshot.savedAt))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                ActiveWorkoutStore.shared.clear()
                onResume(snapshot)
                dismiss()
            } label: {
                Label("接續這場運動", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                saveNow()
            } label: {
                Label(saved ? "已儲存" : "直接存成紀錄", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(saved)

            Button(role: .destructive) {
                ActiveWorkoutStore.shared.clear()
                dismiss()
            } label: {
                Text("丟棄這筆")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentWarm)
            }
            .padding(.top, 2)
        }
    }

    private var explainCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Label("為什麼會這樣", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("iOS 在記憶體吃緊時會直接關掉背景中的 App。把 App 從多工列表滑掉也會立刻中止記錄。這兩種情況系統都不會通知 App，所以無法事先存檔——改用每幾秒自動存檔就是為了應付這件事。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Text("運動中盡量不要把 App 從多工滑掉，鎖屏或切到其他 App 都沒問題。")
                    .font(.caption2)
                    .foregroundStyle(Theme.amber)
            }
        }
    }

    private func saveNow() {
        let session = ActiveWorkoutStore.shared.buildSession(from: snapshot)
        context.insert(session)
        try? context.save()
        Task { await HealthKitSync.syncIfEnabled(session) }
        ActiveWorkoutStore.shared.clear()
        saved = true
        CueService.shared.impact(.heavy)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
    }
}
