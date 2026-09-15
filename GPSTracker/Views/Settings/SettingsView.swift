import SwiftUI
import SwiftData
import CoreLocation
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @Query private var sessions: [WorkoutSession]
    @StateObject private var location = LocationManager.shared

    @State private var showDeleteAll = false
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var weightText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                unitCard
                bodyCard
                cueCard
                mapCard
                permissionCard
                dataCard
                aboutCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
        }
        .screenBackground()
        .navigationTitle("設定")
        .onAppear { weightText = String(format: "%.0f", settings.bodyWeight) }
        .alert("刪除所有資料？", isPresented: $showDeleteAll) {
            Button("取消", role: .cancel) {}
            Button("全部刪除", role: .destructive) { deleteAll() }
        } message: {
            Text("此操作無法復原，共 \(sessions.count) 筆紀錄。")
        }
        .sheet(isPresented: $showExport) {
            if let exportURL {
                VStack(spacing: 16) {
                    Text("已產生 CSV")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    ShareLink(item: exportURL) {
                        Label("分享／儲存", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding()
                .presentationDetents([.height(200)])
            }
        }
    }

    private var unitCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("單位")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Picker("單位", selection: Binding(get: { settings.unit },
                                                 set: { settings.unit = $0 })) {
                    ForEach(DistanceUnit.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var bodyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("個人資料")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Text("體重（公斤）")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TextField("65", text: $weightText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
                        .onChange(of: weightText) { _, newValue in
                            if let value = Double(newValue), value > 20, value < 250 {
                                settings.bodyWeight = value
                            }
                        }
                }
                Text("用於估算消耗熱量（MET 公式），不會離開此裝置。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                HStack {
                    Text("預設單圈距離")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(settings.lapDistance)) m")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Slider(value: Binding(get: { settings.lapDistance },
                                      set: { settings.lapDistance = $0 }),
                       in: 50...2000, step: 50)
                    .tint(Theme.accent)
            }
        }
    }

    private var cueCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("提示")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Toggle("語音播報", isOn: Binding(get: { settings.voiceCues },
                                              set: { settings.voiceCues = $0 }))
                Toggle("震動回饋", isOn: Binding(get: { settings.hapticCues },
                                              set: { settings.hapticCues = $0 }))
                Toggle("GPS 自動暫停", isOn: Binding(get: { settings.autoPause },
                                                 set: { settings.autoPause = $0 }))
            }
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private var mapCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("地圖")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Text("3D 傾斜角")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(settings.mapPitch))°")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Slider(value: Binding(get: { settings.mapPitch },
                                      set: { settings.mapPitch = $0 }),
                       in: 0...75, step: 5)
                    .tint(Theme.accent)
                Toggle("深色模式優先", isOn: Binding(get: { settings.preferDarkMode },
                                                set: { settings.preferDarkMode = $0 }))
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("權限狀態")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Image(systemName: location.isAuthorized ? "location.fill" : "location.slash.fill")
                        .foregroundStyle(location.isAuthorized ? Theme.mint : Theme.amber)
                    Text(permissionText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("系統設定") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                }
                Text("即使完全關閉定位，計圈、間歇、原地運動與手動輸入仍可正常使用。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var permissionText: String {
        switch location.authorizationStatus {
        case .authorizedAlways: return "定位：永遠允許（可背景記錄）"
        case .authorizedWhenInUse: return "定位：使用 App 時允許"
        case .denied: return "定位：已拒絕"
        case .restricted: return "定位：受限制"
        case .notDetermined: return "定位：尚未詢問"
        @unknown default: return "定位：未知狀態"
        }
    }

    private var dataCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("資料")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Text("已儲存紀錄")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(sessions.count) 筆")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Button {
                    exportURL = DataExporter.csv(sessions: sessions)
                    showExport = exportURL != nil
                } label: {
                    Label("匯出全部資料 CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    showDeleteAll = true
                } label: {
                    Label("刪除所有資料", systemImage: "trash")
                }
                .buttonStyle(SecondaryButtonStyle())
                .foregroundStyle(Theme.accentWarm)
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("關於")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("GPS 路跑／健行軌跡記錄器")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text("全程本地端運算與儲存，不連後端伺服器，不需要帳號。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func deleteAll() {
        for session in sessions {
            context.delete(session)
        }
        try? context.save()
        CueService.shared.notify(.warning)
    }
}
