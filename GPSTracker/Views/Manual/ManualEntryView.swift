import SwiftUI
import SwiftData

/// B4：手動輸入（最保底的無定位方案）
struct ManualEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @State private var type: WorkoutType = .manualEntry
    @State private var date = Date()
    @State private var distanceText = ""
    @State private var hours = 0
    @State private var minutes = 30
    @State private var seconds = 0
    @State private var note = ""
    @State private var weather = ""
    @State private var temperature = ""
    @State private var routeKey = ""
    @State private var finishedSession: WorkoutSession?

    private var duration: TimeInterval {
        TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    private var distanceMeters: Double? {
        guard let value = Double(distanceText), value > 0 else { return nil }
        return settings.unit == .metric ? value * 1000 : value * 1609.344
    }

    private var pace: Double? {
        guard let d = distanceMeters, d > 0, duration > 0 else { return nil }
        return duration / (d / 1000)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("不需要任何感測器", systemImage: "hand.raised.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.mint)
                            Text("直接補登今天跑了幾公里、花多久時間，一樣會納入所有圖表與個人紀錄。")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("運動類型")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Picker("類型", selection: $type) {
                                ForEach(WorkoutType.allCases) { item in
                                    Text(item.displayName).tag(item)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(Theme.accent)

                            DatePicker("開始時間", selection: $date)
                                .datePickerStyle(.compact)
                                .tint(Theme.accent)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("距離（\(Fmt.distanceUnitLabel(settings.unit))）")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            TextField("例如 5.2（可留空）", text: $distanceText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))

                            Text("時間")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            HStack {
                                numberPicker("時", value: $hours, range: 0...23)
                                numberPicker("分", value: $minutes, range: 0...59)
                                numberPicker("秒", value: $seconds, range: 0...59)
                            }

                            if let pace {
                                HStack {
                                    Text("推算平均配速")
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Text(Fmt.pace(pace, unit: settings.unit))
                                        .font(.headline.monospacedDigit())
                                        .contentTransition(.numericText())
                                        .foregroundStyle(Theme.mint)
                                }
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("補充資訊（選填）")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            TextField("路線名稱（同路線比較用）", text: $routeKey)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                            HStack(spacing: 10) {
                                TextField("天氣", text: $weather)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                                TextField("氣溫 °C", text: $temperature)
                                    .keyboardType(.numbersAndPunctuation)
                                    .textFieldStyle(.plain)
                                    .frame(width: 100)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                            }
                            TextField("備註", text: $note)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                        }
                    }

                    Button {
                        save()
                    } label: {
                        Label("儲存紀錄", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(duration <= 0)
                    .opacity(duration <= 0 ? 0.5 : 1)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .screenBackground()
            .navigationTitle("手動輸入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .fullScreenCover(item: $finishedSession) { session in
                NavigationStack {
                    WorkoutSummaryView(session: session, isNewlyFinished: true)
                }
                .onDisappear { dismiss() }
            }
        }
    }

    private func numberPicker(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 4) {
            Picker(title, selection: value) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 96)
            .clipped()
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func save() {
        let session = WorkoutSession(type: type,
                                     startDate: date,
                                     endDate: date.addingTimeInterval(duration),
                                     duration: duration,
                                     totalDistance: distanceMeters,
                                     averagePace: pace,
                                     routeKey: routeKey.isEmpty ? nil : routeKey,
                                     notes: note.isEmpty ? nil : note)
        session.calories = IntensityCalculator.calories(type: type,
                                                        duration: duration,
                                                        bodyWeight: settings.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: type,
                                                           duration: duration,
                                                           distance: distanceMeters,
                                                           averagePace: pace,
                                                           elevationGain: nil)
        session.weatherNote = weather.isEmpty ? nil : weather
        session.temperature = Double(temperature)
        context.insert(session)
        try? context.save()
        Task { await HealthKitSync.syncIfEnabled(session) }
        CueService.shared.notify(.success)
        finishedSession = session
    }
}
