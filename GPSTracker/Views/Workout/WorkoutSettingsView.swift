import SwiftUI
import CoreLocation
import UIKit

/// 單一運動項目的獨立設定頁（從運動畫面右上角齒輪進入）。
/// 主畫面的「設定」只放跨項目的雜項，這裡只放跟這個項目有關的東西。
struct WorkoutSettingsView: View {
    let discipline: Discipline

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var location = LocationManager.shared

    @State private var preference: RecordingPreference = .auto

    private var gpsBlocked: Bool { !location.canRecordGPS }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                if discipline.isDual { modeSection }
                if discipline.supportsGPS { gpsSection }
                if discipline.supportsIndoor { indoorSection }
                cueSection
                homeSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("\(discipline.name)設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { preference = settings.preference(for: discipline.id) }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 標頭

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.color(for: discipline.colorType).opacity(0.18))
                    Image(systemName: discipline.icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Theme.color(for: discipline.colorType))
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(discipline.name)
                        .font(.headline)
                    Text(currentModeText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var currentModeText: String {
        guard discipline.isDual else {
            return discipline.supportsGPS ? "GPS 軌跡記錄" : "完全不需要定位"
        }
        let usingGPS = DisciplineCatalog.resolve(discipline,
                                                 preference: preference,
                                                 locationAvailable: location.canRecordGPS)
        return usingGPS ? "目前：GPS 軌跡版" : "目前：免定位版"
    }

    // MARK: 記錄方式

    private var modeSection: some View {
        Section {
            ForEach(RecordingPreference.allCases) { option in
                Button {
                    guard !(option == .gps && gpsBlocked) else { return }
                    preference = option
                    settings.setPreference(option, for: discipline.id)
                    CueService.shared.impact(.soft)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: option.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(option == .gps && gpsBlocked ? Theme.textSecondary : Theme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(option == .gps && gpsBlocked ? Theme.textSecondary : Theme.textPrimary)
                            Text(option == .gps && gpsBlocked
                                 ? "沒有定位權限，無法切換到 GPS 版"
                                 : option.detail)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        if preference == option {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.mint)
                        } else if option == .gps && gpsBlocked {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .disabled(option == .gps && gpsBlocked)
            }

            if gpsBlocked {
                VStack(alignment: .leading, spacing: 8) {
                    Label("定位權限未開啟", systemImage: "location.slash.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                    Text("目前一律使用免定位版。到系統設定開啟定位後，這裡的 GPS 選項才會解鎖。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    if location.isUndetermined {
                        Button("向系統要求定位權限") { location.requestPermission() }
                            .font(.caption.weight(.semibold))
                    } else {
                        Button("前往系統設定") { openSystemSettings() }
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("記錄方式")
        } footer: {
            Text("「自動判斷」會在進入時檢查定位權限：有定位就直接用 GPS 軌跡版，沒有就自動換成免定位版，不用你手動切。")
        }
    }

    // MARK: GPS 專屬

    @ViewBuilder
    private var gpsSection: some View {
        Section {
            Picker("地圖樣式", selection: $settings.mapStyleIndex) {
                Text("標準").tag(0)
                Text("混合").tag(1)
                Text("衛星").tag(2)
            }

            Picker("自動分圈", selection: $settings.gpsAutoLapDistance) {
                Text("關閉").tag(0.0)
                Text("每 500 m").tag(500.0)
                Text("每 1 km").tag(1000.0)
                Text("每 1 mi").tag(1609.344)
            }

            Picker("虛擬配速員", selection: $settings.gpsTargetPace) {
                Text("關閉").tag(0.0)
                Text("7'00\"/km").tag(420.0)
                Text("6'30\"/km").tag(390.0)
                Text("6'00\"/km").tag(360.0)
                Text("5'30\"/km").tag(330.0)
                Text("5'00\"/km").tag(300.0)
                Text("4'30\"/km").tag(270.0)
            }

            Toggle("背景持續記錄", isOn: $settings.backgroundLocation)
            Toggle("自動暫停（停下就暫停）", isOn: $settings.autoPause)
            Toggle("省電取樣（長距離較耐用）", isOn: $settings.batterySaver)
            Toggle("螢幕保持喚醒", isOn: $settings.keepScreenAwake)
            Toggle("進入時直接用大字幕", isOn: $settings.preferBigText)
            Stepper("地圖傾斜 \(Int(settings.mapPitch))°",
                    value: $settings.mapPitch, in: 0...75, step: 5)

            accuracyRow
        } header: {
            Text("GPS 軌跡")
        } footer: {
            Text("背景持續記錄需要「永遠允許」定位；精確位置關閉時軌跡與距離會明顯偏移。")
        }
    }

    @ViewBuilder
    private var accuracyRow: some View {
        HStack {
            Label("定位精度", systemImage: "scope")
            Spacer()
            Text(location.isAuthorized ? location.accuracyText : "未授權")
                .font(.caption)
                .foregroundStyle(location.isReducedAccuracy ? Theme.amber : Theme.textSecondary)
        }
        if location.isAuthorized && location.isReducedAccuracy {
            Button("要求開啟精確定位") { location.requestFullAccuracy() }
        }
    }

    // MARK: 免定位專屬

    @ViewBuilder
    private var indoorSection: some View {
        Section {
            if discipline.id == "rucking" {
                Stepper("預設負重 \(String(format: "%.0f", settings.ruckLoad)) kg",
                        value: $settings.ruckLoad, in: 0...60, step: 1)
            }
            if discipline.indoorType == .lapCounter || discipline.indoorType == .shuttleRun {
                Picker("每圈距離", selection: $settings.lapDistance) {
                    Text("200 m").tag(200.0)
                    Text("300 m").tag(300.0)
                    Text("400 m").tag(400.0)
                    Text("800 m").tag(800.0)
                }
            }
            if discipline.indoorType == .run || discipline.indoorType == .walk || discipline.indoorType == .ruck {
                Stepper("節拍器 \(settings.metronomeBPM) spm",
                        value: $settings.metronomeBPM, in: 120...210, step: 2)
                NavigationLink("步幅校正與精準度") { StrideCalibrationView() }
            }
            HStack {
                Text("體重")
                Spacer()
                Text("\(String(format: "%.0f", settings.bodyWeight)) kg")
                    .foregroundStyle(Theme.textSecondary)
            }
            Stepper("", value: $settings.bodyWeight, in: 30...160, step: 0.5)
                .labelsHidden()
        } header: {
            Text("免定位記錄")
        } footer: {
            Text("免定位版用計步器、氣壓計與動作感測器推算距離與強度，完全不需要 GPS，營區、室內、地下室都能用。")
        }
    }

    // MARK: 提示

    private var cueSection: some View {
        Section("提示與播報") {
            Toggle("語音播報", isOn: $settings.voiceCues)
            Toggle("震動提示", isOn: $settings.hapticCues)
            if settings.voiceCues && discipline.supportsGPS {
                Picker("播報間隔", selection: $settings.announceIntervalRaw) {
                    Text("關閉").tag(0.0)
                    Text("每 500 m").tag(500.0)
                    Text("每 1 km").tag(1000.0)
                    Text("每 2 km").tag(2000.0)
                    Text("每 5 分鐘").tag(-5.0)
                    Text("每 10 分鐘").tag(-10.0)
                }
                Toggle("播報距離", isOn: $settings.announceDistance)
                Toggle("播報配速", isOn: $settings.announcePace)
                Toggle("播報時間", isOn: $settings.announceDuration)
                Toggle("播報與目標配速差", isOn: $settings.announcePacerDelta)
            }
        }
    }

    // MARK: 首頁排列

    private var homeSection: some View {
        Section {
            Toggle("釘選到首頁最上面", isOn: Binding(
                get: { settings.isPinned(id: discipline.id) },
                set: { _ in settings.togglePinned(id: discipline.id) }
            ))
            Toggle("從首頁隱藏這個項目", isOn: Binding(
                get: { settings.isHidden(id: discipline.id) },
                set: { _ in settings.toggleHidden(id: discipline.id) }
            ))
        } header: {
            Text("首頁")
        } footer: {
            Text("隱藏之後仍可從「更多運動」找到這個項目。")
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
