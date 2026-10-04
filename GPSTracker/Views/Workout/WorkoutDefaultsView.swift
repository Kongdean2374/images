import SwiftUI

/// Shared defaults live beside discipline settings, never mutate an existing override.
struct WorkoutDefaultsView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section("未個別覆寫的運動會沿用") {
                Toggle("自動暫停", isOn: $settings.autoPause)
                Toggle("定位失效時輔助記錄", isOn: $settings.assistedTracking)
                Toggle("背景定位", isOn: $settings.backgroundLocation)
                Toggle("省電取樣", isOn: $settings.batterySaver)
                Toggle("保持螢幕喚醒", isOn: $settings.keepScreenAwake)
                Toggle("語音播報", isOn: $settings.voiceCues)
                Toggle("震動提示", isOn: $settings.hapticCues)
                Stepper("分圈距離：\(Int(settings.gpsAutoLapDistance)) m", value: $settings.gpsAutoLapDistance, in: 0...10000, step: 100)
                Stepper("目標配速：\(Int(settings.gpsTargetPace)) 秒/km（0 關閉）", value: $settings.gpsTargetPace, in: 0...1800, step: 10)
                Stepper("播報間隔：\(Int(settings.announceIntervalRaw)) m（負值為分鐘）", value: $settings.announceIntervalRaw, in: -60...10000, step: 1)
                Toggle("播報距離", isOn: $settings.announceDistance)
                Toggle("播報配速", isOn: $settings.announcePace)
                Toggle("播報時間", isOn: $settings.announceDuration)
                Toggle("播報目標差距", isOn: $settings.announcePacerDelta)
            }
        }
        .navigationTitle("共用預設值")
    }
}
