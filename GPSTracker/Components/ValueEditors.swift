import SwiftUI

/// 自訂配速：用滾輪選分與秒，存的一律是「秒 / 公里」。
struct PaceEditorSheet: View {
    let unit: DistanceUnit
    /// 目前值（秒/公里），0 代表關閉
    let initialSecondsPerKM: Double
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 5
    @State private var seconds = 30

    /// 顯示用的單位：公制直接用秒/公里，英制換算成秒/英里
    private var displaySeconds: Int { minutes * 60 + seconds }

    /// 換回秒/公里再存
    private var storedSecondsPerKM: Double {
        unit == .metric ? Double(displaySeconds) : Double(displaySeconds) / 1.609344
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(String(format: "%d'%02d\"", minutes, seconds) + Fmt.paceUnitLabel(unit))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 18)

                HStack(spacing: 0) {
                    Picker("分", selection: $minutes) {
                        ForEach(2...20, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 100)
                    Text("分")
                        .font(.headline)
                        .foregroundStyle(Theme.textSecondary)
                    Picker("秒", selection: $seconds) {
                        ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 100)
                    Text("秒")
                        .font(.headline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(height: 160)

                Text(paceHint)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    Button {
                        onSave(storedSecondsPerKM)
                        dismiss()
                    } label: {
                        Label("使用這個配速", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button {
                        onSave(0)
                        dismiss()
                    } label: {
                        Text("關閉配速員")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .screenBackground()
            .navigationTitle("自訂目標配速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { load() }
        }
        .preferredColorScheme(.dark)
    }

    private var paceHint: String {
        let total = displaySeconds
        guard total > 0 else { return "" }
        let distance = unit == .metric ? 5.0 : 3.1
        let finish = Double(total) * distance
        let label = unit == .metric ? "5 公里" : "5K"
        return "照這個配速，\(label) 大約 \(Fmt.duration(finish))；半馬約 \(Fmt.duration(Double(total) * (unit == .metric ? 21.0975 : 13.1)))"
    }

    private func load() {
        let display = initialSecondsPerKM > 0
            ? (unit == .metric ? initialSecondsPerKM : initialSecondsPerKM * 1.609344)
            : 330
        let total = Int(display.rounded())
        minutes = min(20, max(2, total / 60))
        seconds = total % 60
    }
}

/// 自訂距離：自由輸入數字，可切換公尺 / 公里（或碼 / 英里），存的一律是公尺。
struct DistanceEditorSheet: View {
    let title: String
    let unit: DistanceUnit
    /// 目前值（公尺），0 代表關閉
    let initialMeters: Double
    /// 快捷建議值（公尺）
    var suggestions: [Double] = []
    /// 是否提供「關閉」按鈕
    var allowsOff: Bool = true
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var useLongUnit = false

    private var shortLabel: String { unit == .metric ? "公尺" : "碼" }
    private var longLabel: String { unit == .metric ? "公里" : "英里" }

    private var meters: Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        switch (unit, useLongUnit) {
        case (.metric, false): return value
        case (.metric, true): return value * 1000
        case (.imperial, false): return value * 0.9144
        case (.imperial, true): return value * 1609.344
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(meters.map { Fmt.distance($0, unit: unit) } ?? "—")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(meters == nil ? Theme.textSecondary : Theme.accent)
                    .padding(.top, 18)

                HStack(spacing: 10) {
                    TextField("輸入數字", text: $text)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .font(.title3.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.07)))

                    Picker("", selection: $useLongUnit) {
                        Text(shortLabel).tag(false)
                        Text(longLabel).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
                .padding(.horizontal, 24)

                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("常用")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(suggestions, id: \.self) { value in
                                    Button {
                                        apply(meters: value)
                                        CueService.shared.impact(.soft)
                                    } label: {
                                        Text(Fmt.distance(value, unit: unit))
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 13)
                                            .padding(.vertical, 8)
                                            .background(Capsule().fill(Color.white.opacity(0.08)))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                }

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    Button {
                        if let meters {
                            onSave(meters)
                            dismiss()
                        }
                    } label: {
                        Label("使用這個距離", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(meters == nil)

                    if allowsOff {
                        Button {
                            onSave(0)
                            dismiss()
                        } label: {
                            Text("關閉")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .screenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if initialMeters > 0 { apply(meters: initialMeters) }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func apply(meters value: Double) {
        let long = value >= (unit == .metric ? 1000 : 1609.344)
        useLongUnit = long
        let shown: Double
        switch (unit, long) {
        case (.metric, false): shown = value
        case (.metric, true): shown = value / 1000
        case (.imperial, false): shown = value / 0.9144
        case (.imperial, true): shown = value / 1609.344
        }
        text = shown == shown.rounded()
            ? String(format: "%.0f", shown)
            : String(format: "%.2f", shown)
    }
}

/// 自訂播報間隔：可選以距離或以時間為單位。
/// 存進 announceIntervalRaw：>0 為公尺，<0 為分鐘，0 為關閉。
struct AnnounceIntervalEditorSheet: View {
    let unit: DistanceUnit
    let initialRaw: Double
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var byDistance = true
    @State private var distanceText = "1"
    @State private var useLongUnit = true
    @State private var minutesText = "5"

    private var shortLabel: String { unit == .metric ? "公尺" : "碼" }
    private var longLabel: String { unit == .metric ? "公里" : "英里" }

    private var resultRaw: Double? {
        if byDistance {
            guard let value = Double(distanceText), value > 0 else { return nil }
            switch (unit, useLongUnit) {
            case (.metric, false): return value
            case (.metric, true): return value * 1000
            case (.imperial, false): return value * 0.9144
            case (.imperial, true): return value * 1609.344
            }
        }
        guard let value = Double(minutesText), value > 0 else { return nil }
        return -value
    }

    private var previewText: String {
        guard let raw = resultRaw else { return "—" }
        if raw < 0 { return "每 \(Fmt.decimal(-raw, digits: 0)) 分鐘播報一次" }
        return "每 \(Fmt.distance(raw, unit: unit)) 播報一次"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(previewText)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(resultRaw == nil ? Theme.textSecondary : Theme.accent)
                    .padding(.top, 20)

                Picker("", selection: $byDistance) {
                    Text("依距離").tag(true)
                    Text("依時間").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)

                if byDistance {
                    HStack(spacing: 10) {
                        TextField("1", text: $distanceText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.plain)
                            .font(.title3.monospacedDigit())
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.07)))
                        Picker("", selection: $useLongUnit) {
                            Text(shortLabel).tag(false)
                            Text(longLabel).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                    }
                    .padding(.horizontal, 24)
                } else {
                    HStack(spacing: 10) {
                        TextField("5", text: $minutesText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.plain)
                            .font(.title3.monospacedDigit())
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.07)))
                        Text("分鐘")
                            .font(.headline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 130)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    Button {
                        if let raw = resultRaw {
                            onSave(raw)
                            dismiss()
                        }
                    } label: {
                        Label("使用這個間隔", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(resultRaw == nil)

                    Button {
                        onSave(0)
                        dismiss()
                    } label: {
                        Text("關閉播報")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .screenBackground()
            .navigationTitle("自訂播報間隔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { load() }
        }
        .preferredColorScheme(.dark)
    }

    private func load() {
        if initialRaw < 0 {
            byDistance = false
            minutesText = String(format: "%.0f", -initialRaw)
        } else if initialRaw > 0 {
            byDistance = true
            let long = initialRaw >= (unit == .metric ? 1000 : 1609.344)
            useLongUnit = long
            let shown: Double
            switch (unit, long) {
            case (.metric, false): shown = initialRaw
            case (.metric, true): shown = initialRaw / 1000
            case (.imperial, false): shown = initialRaw / 0.9144
            case (.imperial, true): shown = initialRaw / 1609.344
            }
            distanceText = shown == shown.rounded()
                ? String(format: "%.0f", shown)
                : String(format: "%.2f", shown)
        }
    }
}

/// 會自動換行的標籤列，用來排自訂快捷選項。
struct FlowChips: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
