import SwiftUI

/// 滑動確認。手指要從左端一路拖到右端才會觸發，
/// 中途放掉會彈回原位，必須重來一次——運動中口袋誤觸不會意外解鎖。
struct SlideToConfirm: View {
    let title: String
    var icon: String = "chevron.right"
    var tint: Color = Theme.accent
    /// 要滑過多少比例才算數
    var threshold: Double = 0.85
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    @State private var completed = false
    @State private var shimmer = false

    private let height: CGFloat = 64
    private let inset: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let knobSize = height - inset * 2
            let travel = max(1, geo.size.width - knobSize - inset * 2)
            let progress = min(1, max(0, offset / travel))

            ZStack(alignment: .leading) {
                // 軌道
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )

                // 已滑過的部分
                Capsule()
                    .fill(tint.opacity(0.30))
                    .frame(width: offset + knobSize + inset * 2)

                // 提示文字
                Text(completed ? "已解鎖" : title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55 + 0.35 * shimmerPhase))
                    .frame(maxWidth: .infinity)
                    .opacity(1 - progress * 1.4)
                    .allowsHitTesting(false)

                // 滑塊
                ZStack {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    Image(systemName: completed ? "checkmark" : icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: knobSize, height: knobSize)
                .padding(.leading, inset)
                .offset(x: offset)
                .scaleEffect(isDragging ? 1.06 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !completed else { return }
                            if !isDragging {
                                isDragging = true
                                CueService.shared.impact(.light)
                            }
                            offset = min(travel, max(0, value.translation.width))
                        }
                        .onEnded { _ in
                            isDragging = false
                            guard !completed else { return }
                            if offset / travel >= threshold {
                                // 滑到底：先補滿再觸發
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                                    offset = travel
                                }
                                completed = true
                                CueService.shared.impact(.heavy)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                                    action()
                                }
                            } else {
                                // 沒滑到底：彈回去，要重新滑一次
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    offset = 0
                                }
                                if offset > travel * 0.15 { CueService.shared.impact(.soft) }
                            }
                        }
                )
            }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("向右滑動以確認")
        .accessibilityAction { action() }
    }

    private var shimmerPhase: Double { shimmer ? 1 : 0 }
}
