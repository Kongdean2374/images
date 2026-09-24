import SwiftUI
import ChaiNetCore

struct SectionTitle: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Big number tile used on result pages.
struct MetricTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var caption: String?
    var symbol: String
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .cardStyle(padding: 14)
    }
}

/// Circular 0–100 score.
struct ScoreRing: View {
    let score: Int?
    var label: String
    var size: CGFloat = 64
    @State private var animated: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Theme.border, lineWidth: size / 9)
                Circle()
                    .trim(from: 0, to: animated)
                    .stroke(Theme.scoreColor(score), style: StrokeStyle(lineWidth: size / 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Format.score(score))
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: size, height: size)
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.8)) { animated = Double(score ?? 0) / 100 } }
        .onChange(of: score) { _, new in withAnimation(.easeOut(duration: 0.5)) { animated = Double(new ?? 0) / 100 } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Format.score(score)) 分")
    }
}

/// Expandable technical section (progressive disclosure).
struct TechnicalSection<Content: View>: View {
    let title: String
    let symbol: String
    @State var expanded: Bool
    @ViewBuilder var content: () -> Content

    init(_ title: String, symbol: String, expanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self._expanded = State(initialValue: expanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardStyle(padding: 14)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var valueColor: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.footnote).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(value).font(.footnote.monospacedDigit()).foregroundStyle(valueColor).multilineTextAlignment(.trailing)
        }
    }
}

/// Row for platform-limited values: shows "無法取得" + reason instead of fake data.
struct AvailabilityRow<T: Codable & Sendable & Hashable>: View {
    let key: String
    let availability: Availability<T>
    let format: (T) -> String

    var body: some View {
        switch availability {
        case .available(let v):
            KeyValueRow(key: key, value: format(v))
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 2) {
                KeyValueRow(key: key, value: "無法取得", valueColor: Theme.textSecondary)
                Text(reason).font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.8))
            }
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension DiagnosticSeverity {
    var color: Color {
        switch self {
        case .info: Theme.info
        case .warning: Theme.warning
        case .critical: Theme.critical
        }
    }
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

extension Likelihood {
    var color: Color {
        switch self {
        case .supported: Theme.critical
        case .likely: Theme.critical
        case .possible: Theme.warning
        case .unlikely, .noEvidence, .broadIssueUnlikely: Theme.info
        case .insufficientEvidence: Theme.textSecondary
        case .notTested: Theme.textSecondary.opacity(0.8)
        case .ruledOut: Theme.good
        }
    }
    var shortName: String {
        switch self {
        case .supported: "實測支持"
        case .likely: "可能性高"
        case .possible: "有可能"
        case .unlikely: "可能性低"
        case .noEvidence: "無證據"
        case .broadIssueUnlikely: "廣泛問題不太可能"
        case .insufficientEvidence: "證據不足"
        case .notTested: "未測試"
        case .ruledOut: "已排除"
        }
    }
}

extension SuitabilityVerdict {
    var displayName: String {
        switch self {
        case .great: "極佳"
        case .playable: "可用"
        case .degraded: "受影響"
        case .unsuitable: "不適合"
        }
    }
    var color: Color {
        switch self {
        case .great: Theme.good
        case .playable: Theme.accent
        case .degraded: Theme.warning
        case .unsuitable: Theme.critical
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(Theme.textSecondary)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

/// Primary call-to-action button.
struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(Color.black.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}
