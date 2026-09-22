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

    private let height: CGFloat = 64
    private let inset: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("向右滑動以確認")
        .accessibilityAction { action() }
    }

    private func content(width: CGFloat) -> some View {
        let knobSize: CGFloat = height - inset * 2
        let travel: CGFloat = max(1, width - knobSize - inset * 2)
        let progress: CGFloat = min(1, max(0, offset / travel))

        return ZStack(alignment: .leading) {
            track
            filled(width: offset + knobSize + inset * 2)
            label(progress: progress)
            knob(size: knobSize, travel: travel)
        }
    }

    private var track: some View {
        Capsule()
            .fill(Color.white.opacity(0.10))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    private func filled(width: CGFloat) -> some View {
        Capsule()
            .fill(tint.opacity(0.30))
            .frame(width: width)
    }

    private func label(progress: CGFloat) -> some View {
        Text(completed ? "已解鎖" : title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .opacity(Double(1 - progress * 1.4))
            .allowsHitTesting(false)
    }

    private func knob(size: CGFloat, travel: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            Image(systemName: completed ? "checkmark" : icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .padding(.leading, inset)
        .offset(x: offset)
        .scaleEffect(isDragging ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
        .gesture(dragGesture(travel: travel))
    }

    private func dragGesture(travel: CGFloat) -> some Gesture {
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
                if offset / travel >= CGFloat(threshold) {
                    complete(travel: travel)
                } else {
                    cancel()
                }
            }
    }

    private func complete(travel: CGFloat) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            offset = travel
        }
        completed = true
        CueService.shared.impact(.heavy)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            action()
        }
    }

    private func cancel() {
        // 沒滑到底：彈回去，要重新滑一次
        if offset > 10 { CueService.shared.impact(.soft) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            offset = 0
        }
    }
}
