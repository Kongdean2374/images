import SwiftUI
import AVKit

/// 把軌跡回放輸出成影片，可直接分享或存到相簿。
struct RouteVideoExportView: View {
    let session: WorkoutSession

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var exporter = RouteVideoExporter()

    @State private var seconds: Double = 12

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    previewCard
                    if case .done(let url) = exporter.stage {
                        resultCard(url)
                    } else {
                        optionsCard
                        actionButton
                    }
                    infoCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .screenBackground()
            .navigationTitle("匯出回放動畫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("關閉") {
                        exporter.cancel()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var previewCard: some View {
        GlassCard(padding: 16) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                    VStack(spacing: 8) {
                        Image(systemName: stageIcon)
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.pulse, isActive: isWorking)
                        Text(stageText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if case .rendering(let value) = exporter.stage {
                            ProgressView(value: value)
                                .tint(Theme.accent)
                                .padding(.horizontal, 40)
                            Text("\(Int(value * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.vertical, 26)
                }
                .frame(height: 190)
            }
        }
    }

    private var optionsCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("影片長度", systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(Int(seconds)) 秒")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: $seconds, in: 6...30, step: 1)
                    .tint(Theme.accent)
                Text("1080 × 1920 直式、60 fps，適合限時動態與訊息分享。時間越長算越久。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var actionButton: some View {
        Button {
            Task { await exporter.export(session: session, unit: settings.unit, seconds: seconds) }
        } label: {
            Label(isWorking ? "產生中⋯" : "產生動畫影片", systemImage: "film")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isWorking)
    }

    private func resultCard(_ url: URL) -> some View {
        GlassCard(padding: 16) {
            VStack(spacing: 14) {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                ShareLink(item: url) {
                    Label("分享 / 儲存影片", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("重新產生") {
                    exporter.cancel()
                    Task { await exporter.export(session: session, unit: settings.unit, seconds: seconds) }
                }
                .buttonStyle(SecondaryButtonStyle())

                Text("分享時選「儲存影片」就會存進相簿。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var infoCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("影片裡會有什麼", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                row("逐漸長出來的路線，依配速由藍到紅上色")
                row("即時的距離與時間，跟著路線一起跑")
                row("總距離、\(session.prefersSpeed ? "平均速度" : "平均配速")、消耗熱量")
                row("運動名稱與日期")
                Text("影片在這支手機上算圖，不會上傳任何地方。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }
        }
    }

    private func row(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.mint)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var isWorking: Bool {
        switch exporter.stage {
        case .snapshotting, .rendering, .writing: return true
        default: return false
        }
    }

    private var stageIcon: String {
        switch exporter.stage {
        case .idle: return "film"
        case .snapshotting: return "map"
        case .rendering: return "paintbrush.pointed.fill"
        case .writing: return "square.and.arrow.down"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var stageText: String {
        switch exporter.stage {
        case .idle: return "準備好了，按下面開始"
        case .snapshotting: return "取得地圖底圖⋯"
        case .rendering: return "逐格繪製動畫⋯"
        case .writing: return "寫入影片檔⋯"
        case .done: return "完成"
        case .failed(let message): return message
        }
    }
}
