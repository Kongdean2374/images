import SwiftUI

/// 全 App 共用的視覺語言。
enum Theme {
    static let accent = Color(hex: "#0A84FF")
    static let corner: CGFloat = 22

    static func heroGradient(for level: BurnLevel) -> LinearGradient {
        switch level {
        case .good:
            return LinearGradient(
                colors: [Color(hex: "#0A84FF"), Color(hex: "#32D74B")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .warning:
            return LinearGradient(
                colors: [Color(hex: "#FF9F0A"), Color(hex: "#FFD60A")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .over:
            return LinearGradient(
                colors: [Color(hex: "#FF453A"), Color(hex: "#FF375F")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    static let pageBackground = LinearGradient(
        colors: [Color(uiColor: .systemGroupedBackground), Color(uiColor: .systemGroupedBackground)],
        startPoint: .top, endPoint: .bottom
    )
}

/// 統一的卡片外觀
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    var corner: CGFloat = Theme.corner

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16, corner: CGFloat = Theme.corner) -> some View {
        modifier(CardBackground(padding: padding, corner: corner))
    }
}

/// 標題 + 右側附件的小工具列
struct CardHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
            Text(title).font(.headline)
            Spacer()
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil) {
        self.init(title: title, systemImage: systemImage, trailing: { EmptyView() })
    }
}
