import SwiftUI

/// 破紀錄慶祝動畫：光暈 + 彩帶，1 秒內結束，不阻擋操作。
struct CelebrationOverlay: View {
    let titles: [String]
    @State private var animate = false
    @State private var glow = false

    private let colors: [Color] = [Theme.accent, Theme.mint, Theme.amber, Theme.accentWarm, Theme.violet]

    var body: some View {
        ZStack {
            ForEach(0..<26, id: \.self) { index in
                Capsule()
                    .fill(colors[index % colors.count])
                    .frame(width: 6, height: 14)
                    .rotationEffect(.degrees(Double(index) * 37))
                    .offset(x: animate ? CGFloat.random(in: -150...150) : 0,
                            y: animate ? CGFloat.random(in: -260...(-60)) : 0)
                    .opacity(animate ? 0 : 1)
                    .animation(.easeOut(duration: 0.9).delay(Double(index) * 0.012), value: animate)
            }

            VStack(spacing: 6) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.amber)
                    .shadow(color: Theme.amber.opacity(glow ? 0.9 : 0.2), radius: glow ? 18 : 4)
                Text("刷新紀錄！")
                    .font(.headline)
                    .foregroundStyle(.white)
                ForEach(titles, id: \.self) { title in
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .scaleEffect(animate ? 1 : 0.7)
            .opacity(animate ? 1 : 0)
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: animate)
        }
        .allowsHitTesting(false)
        .onAppear {
            animate = true
            withAnimation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true)) {
                glow = true
            }
            CueService.shared.notify(.success)
        }
    }
}
