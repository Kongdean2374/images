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
    @State private var showPaceEditor = false
    @State private var showLapEditor = false
    @State private var showAnnounceEditor = false
    @State private var showLapCounterEditor = false
    @State private var editingPresets = false

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
            .sheet(isPresented: $showPaceEditor) {
                PaceEditorSheet(unit: settings.unit,
                                initialSecondsPerKM: settings.gpsTargetPace) { value in
                    settings.gpsTargetPace = value
                    if value > 0 { settings.addCustomPace(value) }
                }
            }
            .sheet(isPresented: $showLapEditor) {
                DistanceEditorSheet(title: "自訂分圈距離",
                                    unit: settings.unit,
                                    initialMeters: settings.gpsAutoLapDistance,
                                    suggestions: [200, 400, 500, 1000, 1609.344, 2000, 5000]) { value in
                    settings.gpsAutoLapDistance = value
                    if value > 0 { settings.addCustomLapDistance(value) }
                }
            }
            .sheet(isPresented: $showAnnounceEditor) {
                AnnounceIntervalEditorSheet(unit: settings.unit,
                                            initialRaw: settings.announceIntervalRaw) { value in
                    settings.announceIntervalRaw = value
                }
            }
            .sheet(isPresented: $showLapCounterEditor) {
                DistanceEditorSheet(title: "自訂每圈距離",
                                    unit: settings.unit,
                                    initialMeters: settings.lapDistance,
                                    suggestions: [100, 200, 300, 400, 800, 1000],
                                    allowsOff: false) { value in
                    settings.lapDistance = value
                }
            }
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

            Picker("軌跡上色", selection: Binding(
                get: { settings.routeColorMode },
                set: { settings.routeColorMode = $0 }
            )) {
                ForEach(RouteColorMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            valueRow(title: "自動分圈",
                     value: settings.gpsAutoLapDistance > 0
                        ? Fmt.distance(settings.gpsAutoLapDistance, unit: settings.unit)
                        : "關閉",
                     icon: "flag.checkered") {
                showLapEditor = true
            }

            valueRow(title: "虛擬配速員",
                     value: settings.gpsTargetPace > 0
                        ? Fmt.pace(settings.gpsTargetPace, unit: settings.unit) + Fmt.paceUnitLabel(settings.unit)
                        : "關閉",
                     icon: "figure.run.circle") {
                showPaceEditor = true
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
            Text("分圈距離與目標配速都可以自己輸入任意數值，不限於預設選項。軌跡上色選「絕對速度」時，尺規會跟著當下最高速即時重新分級。背景持續記錄需要「永遠允許」定位。")
        }

        presetSection
    }

    /// 自訂快捷清單：運動當下快捷列上會出現的選項，由使用者自己決定
    private var presetSection: some View {
        Section {
            DisclosureGroup("編輯快捷選項", isExpanded: $editingPresets) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("目標配速")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    presetChips(values: settings.customPaces,
                                label: { Fmt.pace($0, unit: settings.unit) },
                                remove: { settings.removeCustomPace($0) },
                                add: { showPaceEditor = true })

                    Divider().overlay(Color.white.opacity(0.08))

                    Text("分圈距離")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    presetChips(values: settings.customLapDistances,
                                label: { Fmt.distance($0, unit: settings.unit) },
                                remove: { settings.removeCustomLapDistance($0) },
                                add: { showLapEditor = true })

                    Button("恢復成預設清單") { settings.resetCustomLists() }
                        .font(.caption.weight(.semibold))
                        .padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("快捷選項")
        } footer: {
            Text("這裡列出的值，會直接出現在運動畫面的快捷列上。點一下標籤可以刪除；用「自訂」新增的值會自動加進來，最多 8 個。")
        }
    }

    private func presetChips(values: [Double],
                             label: @escaping (Double) -> String,
                             remove: @escaping (Double) -> Void,
                             add: @escaping () -> Void) -> some View {
        FlowChips {
            ForEach(values, id: \.self) { value in
                Button {
                    remove(value)
                    CueService.shared.impact(.soft)
                } label: {
                    HStack(spacing: 4) {
                        Text(label(value))
                            .monospacedDigit()
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.accent.opacity(0.18)))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            Button(action: add) {
                Label("新增", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.violet.opacity(0.22)))
                    .foregroundStyle(Theme.violet)
            }
            .buttonStyle(.plain)
        }
    }

    /// 一列：左邊名稱、右邊目前值，點了開自訂編輯器
    private func valueRow(title: String,
                          value: String,
                          icon: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
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
                valueRow(title: "每圈距離",
                         value: Fmt.distance(settings.lapDistance, unit: settings.unit),
                         icon: "repeat.circle") {
                    showLapCounterEditor = true
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
                valueRow(title: "播報間隔",
                         value: settings.announceIntervalText,
                         icon: "speaker.wave.2") {
                    showAnnounceEditor = true
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
