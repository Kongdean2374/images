import SwiftUI

/// 使用說明：以圖示卡為主，文字精簡。
struct UserGuideView: View {

    private struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        let tint: Color
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private let gpsItems: [Item] = [
        Item(icon: "figure.run", title: "GPS 路跑", detail: "軌跡依配速變色，鏡頭跟著你轉", tint: Theme.accent),
        Item(icon: "figure.hiking", title: "GPS 健行", detail: "累積爬升與下降、海拔剖面", tint: Theme.mint),
        Item(icon: "play.circle", title: "軌跡回放", detail: "結束後逐幀重播，最快段特寫", tint: Theme.violet),
        Item(icon: "square.and.arrow.up", title: "戰績卡片", detail: "一鍵產生路線縮圖分享", tint: Theme.amber)
    ]

    private let noGPSItems: [Item] = [
        Item(icon: "figure.walk", title: "走路／跑步", detail: "計步器 + 個人步幅算距離", tint: Theme.accent),
        Item(icon: "arrow.triangle.capsulepath", title: "營區計圈", detail: "設好圈距，每圈按一下", tint: Theme.amber),
        Item(icon: "timer", title: "室內間歇", detail: "衝刺休息循環，語音提示", tint: Theme.accentWarm),
        Item(icon: "figure.jumprope", title: "原地運動", detail: "自動計次，可設循環組數", tint: Theme.violet),
        Item(icon: "medal.fill", title: "體能測驗", detail: "三項測驗自動評等", tint: Theme.amber),
        Item(icon: "metronome", title: "步頻節拍器", detail: "跟著拍子穩定步頻", tint: Theme.mint)
    ]

    private let dataItems: [Item] = [
        Item(icon: "square.and.arrow.down", title: "一鍵匯入", detail: "健康 App 的歷史訓練全帶進來", tint: Theme.mint),
        Item(icon: "arrow.left.arrow.right", title: "雙向同步", detail: "這裡記錄的會寫回健康 App", tint: Theme.accent),
        Item(icon: "wand.and.stars", title: "步幅校正", detail: "自動算出步幅與精準度百分比", tint: Theme.violet),
        Item(icon: "chart.xyaxis.line", title: "訓練負荷", detail: "急慢性比、體能與疲勞指數", tint: Theme.amber)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                section("需要定位", items: gpsItems)
                section("不需定位", items: noGPSItems)
                section("資料與分析", items: dataItems)
                tipsCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .screenBackground()
        .navigationTitle("使用說明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var heroCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 76, height: 76)
                        .shadow(color: Theme.accent.opacity(0.5), radius: 16)
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(-16))
                }
                Text("\(SportCatalog.all.count)＋ 種運動，訊號好壞都能練")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("進入項目會自動判斷用 GPS 版還是免定位版\n全部資料留在這台裝置上，不上傳任何地方")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    private func section(_ title: String, items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(item.tint.opacity(0.18))
                            Image(systemName: item.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(item.tint)
                        }
                        .frame(width: 40, height: 40)
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(item.detail)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                    .padding(13)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.card)
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Theme.cardStroke, lineWidth: 1))
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tipsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("小技巧", systemImage: "lightbulb.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.amber)
                tip("先用 GPS 跑一次，步幅會自動校正，之後沒訊號也準")
                tip("跑道計圈比步幅估算更準，體測 3000 公尺建議用計圈")
                tip("運動後補一個 RPE 分數，訓練負荷會更貼近真實感受")
                tip("在分析頁可以看到哪些資料還缺，補齊後圖表更完整")
                tip("每個運動畫面右上角的齒輪，是那個項目專屬的設定")
                tip("首頁長按任一項目，可以釘選到最上面或從首頁隱藏")
                tip("備份時可以勾選加密，存到雲端硬碟才安全")
            }
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.mint)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
