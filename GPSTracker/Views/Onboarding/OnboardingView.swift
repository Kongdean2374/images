import SwiftUI

/// 首次開啟導覽：圖為主、字精簡，最後一次把權限說清楚。
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var location = LocationManager.shared
    @StateObject private var health = HealthKitManager.shared

    @State private var page = 0
    @State private var animate = false
    @State private var notificationsGranted = false

    private let pageCount = 5

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear],
                           center: .top, startRadius: 20, endRadius: 520)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < pageCount - 1 {
                        Button("略過") { finish() }
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                TabView(selection: $page) {
                    welcomePage.tag(0)
                    gpsPage.tag(1)
                    noGPSPage.tag(2)
                    healthPage.tag(3)
                    permissionPage.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                indicator
                    .padding(.bottom, 14)

                controls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 26)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { animate = true }
    }

    // MARK: 頁面

    private var welcomePage: some View {
        page(illustration: gaugeIllustration,
             title: "記錄每一次訓練",
             subtitle: "九種模式，訊號好壞都能練。\n所有資料留在這台裝置上。")
    }

    private var gpsPage: some View {
        page(illustration: routeIllustration,
             title: "GPS 模式",
             subtitle: "軌跡依配速變色、鏡頭跟著你轉，\n結束後還能回放整段路線。")
    }

    private var noGPSPage: some View {
        page(illustration: modesIllustration,
             title: "沒有定位也能用",
             subtitle: "營區、室內、地下室都行。\n計圈、間歇、原地運動、體能測驗。")
    }

    private var healthPage: some View {
        page(illustration: syncIllustration,
             title: "和健康 App 互通",
             subtitle: "這裡記錄的會寫進健康 App，\n其他 App 的歷史訓練也能一鍵匯入。")
    }

    private var permissionPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("開啟你需要的功能")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 10)
                Text("全部都是選用的，拒絕也能正常使用")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                permissionRow(icon: "location.fill",
                              title: "定位",
                              detail: "記錄戶外軌跡、距離與配速",
                              granted: location.isAuthorized) {
                    location.requestPermission()
                }
                permissionRow(icon: "figure.walk.motion",
                              title: "動作與健身",
                              detail: "步數、步頻、樓層與原地計次",
                              granted: PedometerManager.isStepCountingAvailable) {
                    // 首次讀取計步資料時系統會自動詢問
                    Task { _ = await PedometerManager.query(from: Date().addingTimeInterval(-3600), to: Date()) }
                }
                permissionRow(icon: "heart.fill",
                              title: "健康 App",
                              detail: "雙向同步與匯入歷史紀錄",
                              granted: health.isReady) {
                    Task {
                        let ok = await health.requestAuthorization()
                        if ok { settings.healthKitEnabled = true }
                    }
                }
                permissionRow(icon: "bell.badge.fill",
                              title: "通知",
                              detail: "達成目標與背景更新提醒",
                              granted: notificationsGranted) {
                    Task { notificationsGranted = await NotificationManager.requestAuthorization() }
                }

                Text("你隨時可以在「設定」裡調整，或閱讀完整的隱私政策。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
    }

    private func page<Illustration: View>(illustration: Illustration,
                                          title: String,
                                          subtitle: String) -> some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)
            illustration
                .frame(height: 250)
            VStack(spacing: 10) {
                Text(title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 28)
    }

    private func permissionRow(icon: String,
                               title: String,
                               detail: String,
                               granted: Bool,
                               action: @escaping () -> Void) -> some View {
        GlassCard(padding: 14) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((granted ? Theme.mint : Theme.accent).opacity(0.18))
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(granted ? Theme.mint : Theme.accent)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.mint)
                } else {
                    Button("開啟", action: action)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent.opacity(0.25)))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 插圖

    private var gaugeIllustration: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .rotationEffect(.degrees(126))
            Circle()
                .trim(from: 0.08, to: animate ? 0.75 : 0.08)
                .stroke(AngularGradient(colors: [Theme.accent, Theme.mint, Theme.amber, Theme.accentWarm],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .rotationEffect(.degrees(126))
                .animation(.easeOut(duration: 1.1), value: animate)
            Image(systemName: "location.north.fill")
                .font(.system(size: 62, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-16))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
        }
        .frame(width: 230, height: 230)
    }

    private var routeIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Theme.cardStroke, lineWidth: 1)
                )
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                Path { path in
                    path.move(to: CGPoint(x: w * 0.15, y: h * 0.82))
                    path.addCurve(to: CGPoint(x: w * 0.52, y: h * 0.48),
                                  control1: CGPoint(x: w * 0.3, y: h * 0.62),
                                  control2: CGPoint(x: w * 0.3, y: h * 0.5))
                    path.addCurve(to: CGPoint(x: w * 0.85, y: h * 0.18),
                                  control1: CGPoint(x: w * 0.72, y: h * 0.46),
                                  control2: CGPoint(x: w * 0.68, y: h * 0.24))
                }
                .trim(from: 0, to: animate ? 1 : 0)
                .stroke(LinearGradient(colors: [Theme.accent, Theme.violet, Theme.accentWarm],
                                       startPoint: .bottomLeading, endPoint: .topTrailing),
                        style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
                .animation(.easeInOut(duration: 1.4), value: animate)

                Circle()
                    .fill(Theme.mint)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .position(x: w * 0.15, y: h * 0.82)
                Circle()
                    .fill(Theme.accentWarm)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .position(x: w * 0.85, y: h * 0.18)
                    .opacity(animate ? 1 : 0)
                    .animation(.easeIn(duration: 0.4).delay(1.2), value: animate)
            }
            .padding(22)
        }
        .frame(width: 250, height: 230)
    }

    private var modesIllustration: some View {
        let icons: [(String, Color)] = [
            ("arrow.triangle.capsulepath", Theme.amber),
            ("timer", Theme.accentWarm),
            ("figure.jumprope", Theme.violet),
            ("figure.walk", Theme.accent),
            ("medal.fill", Theme.amber),
            ("metronome", Theme.mint)
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                         spacing: 16) {
            ForEach(Array(icons.enumerated()), id: \.offset) { index, item in
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(item.1.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(item.1.opacity(0.35), lineWidth: 1))
                    Image(systemName: item.0)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(item.1)
                }
                .frame(height: 68)
                .scaleEffect(animate ? 1 : 0.6)
                .opacity(animate ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(index) * 0.07), value: animate)
            }
        }
        .frame(width: 260)
    }

    private var syncIllustration: some View {
        VStack(spacing: 22) {
            HStack(spacing: 34) {
                illustrationBadge(icon: "location.north.fill", tint: Theme.accent, label: "本 App")
                illustrationBadge(icon: "heart.fill", tint: Theme.accentWarm, label: "健康 App")
            }
            VStack(spacing: 10) {
                arrowRow(icon: "arrow.right", text: "運動寫入健康", tint: Theme.accent)
                arrowRow(icon: "arrow.left", text: "歷史一鍵匯入", tint: Theme.mint)
            }
        }
    }

    private func illustrationBadge(icon: String, tint: Color, label: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(tint.opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(tint.opacity(0.4), lineWidth: 1))
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 92, height: 92)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func arrowRow(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    // MARK: 控制

    private var indicator: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Theme.accent : Color.white.opacity(0.18))
                    .frame(width: index == page ? 22 : 7, height: 7)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: page)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                if page < pageCount - 1 {
                    withAnimation { page += 1 }
                    CueService.shared.impact(.soft)
                } else {
                    finish()
                }
            } label: {
                Text(page < pageCount - 1 ? "繼續" : "開始使用")
            }
            .buttonStyle(PrimaryButtonStyle())

            if page == pageCount - 1 {
                NavigationLink {
                    LegalView(document: .privacy)
                } label: {
                    Text("查看隱私政策")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func finish() {
        settings.hasSeenOnboarding = true
        CueService.shared.impact(.medium)
        dismiss()
    }
}
