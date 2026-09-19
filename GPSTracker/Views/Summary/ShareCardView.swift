import SwiftUI
import MapKit
import CoreLocation

/// 分享戰績卡片：路徑縮圖 + 關鍵數據排版。
struct ShareCardView: View {
    let session: WorkoutSession
    var routeImage: UIImage?
    var unit: DistanceUnit = .metric

    private var splits: [SplitSegment] {
        StatsEngine.splits(for: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.type.displayName)
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(Fmt.dateTime(session.startDate))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Image(systemName: session.type.systemImage)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.color(for: session.type))
            }
            .padding(.bottom, 20)

            if let routeImage {
                Image(uiImage: routeImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.bottom, 20)
            } else if !splits.isEmpty {
                splitsBar
                    .frame(height: 170)
                    .padding(.bottom, 20)
            }

            HStack(spacing: 0) {
                cardMetric("距離", Fmt.distanceValue(session.totalDistance, unit: unit),
                           Fmt.distanceUnitLabel(unit), Theme.accent)
                cardMetric("時間", Fmt.duration(session.duration), "", .white)
                cardMetric("平均配速", Fmt.pace(session.averagePace, unit: unit),
                           Fmt.paceUnitLabel(unit), Theme.mint)
            }
            .padding(.bottom, 14)

            HStack(spacing: 0) {
                if let gain = session.elevationGain, gain > 1 {
                    cardMetric("爬升", String(format: "%.0f", gain), "m", Theme.amber)
                }
                if let cal = session.calories {
                    cardMetric("熱量", String(format: "%.0f", cal), "kcal", Theme.accentWarm)
                }
                if let score = session.intensityScore {
                    cardMetric("強度", String(format: "%.0f", score),
                               IntensityCalculator.label(for: score), Theme.violet)
                }
                if !session.laps.isEmpty {
                    cardMetric("圈數", "\(session.laps.count)", "圈", Theme.mint)
                }
            }

            Divider().overlay(Color.white.opacity(0.15)).padding(.vertical, 18)

            HStack {
                Text("GPS 軌跡記錄器")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("#本地紀錄 #不連雲端")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(30)
        .background(
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .frame(width: 720)
    }

    private var splitsBar: some View {
        let maxPace = splits.compactMap { $0.pace }.max() ?? 1
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(splits) { split in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.paceColor(fraction: 1 - ((split.pace ?? maxPace) / max(maxPace, 1))))
                        .frame(height: max(12, 150 * ((split.pace ?? maxPace) / max(maxPace, 1))))
                    Text("\(split.index)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func cardMetric(_ title: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
