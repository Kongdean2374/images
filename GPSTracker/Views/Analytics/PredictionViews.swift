import SwiftUI

/// 比賽成績預測
struct RacePredictionCard: View {
    let predictions: [RacePrediction]
    var unit: DistanceUnit = .metric

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("比賽成績預測", systemImage: "flag.checkered.2.crossed")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }

                if predictions.isEmpty {
                    EmptyStateView(systemImage: "flag.checkered",
                                   title: "還沒有足夠的軌跡",
                                   message: "有 GPS 軌跡的紀錄越多，預測越準。",
                                   tint: Theme.violet,
                                   compact: true)
                } else {
                    ForEach(predictions) { prediction in
                        VStack(spacing: 6) {
                            HStack(spacing: 10) {
                                Text(prediction.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 92, alignment: .leading)
                                Text(Fmt.duration(prediction.predictedTime))
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.violet)
                                Spacer()
                                Text(Fmt.pace(prediction.pace, unit: unit))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.mint)
                            }
                            HStack(spacing: 6) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.08))
                                        Capsule()
                                            .fill(color(for: prediction.confidence))
                                            .frame(width: geo.size.width * max(0.03, prediction.confidence))
                                    }
                                }
                                .frame(height: 5)
                                Text(prediction.confidenceText)
                                    .font(.system(size: 10))
                                    .foregroundStyle(color(for: prediction.confidence))
                                    .frame(width: 60, alignment: .trailing)
                            }
                            HStack {
                                Text("依據 \(prediction.basedOnLabel) 的最佳成績（\(Fmt.date(prediction.basedOnDate))）")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                            }
                        }
                        .padding(.vertical, 4)
                        Divider().overlay(Color.white.opacity(0.06))
                    }

                    Text("使用 Riegel 公式由你的最佳分段外推。外推距離越遠、資料越舊，可信度越低，實際成績還受地形、天氣與當天狀態影響。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func color(for confidence: Double) -> Color {
        switch confidence {
        case ..<0.35: return Theme.accentWarm
        case ..<0.6: return Theme.amber
        case ..<0.8: return Theme.accent
        default: return Theme.mint
        }
    }
}

/// 訓練強度分佈（80/20）
struct IntensityBalanceCard: View {
    let balance: IntensityBalance

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("強度分佈", systemImage: "scalemass")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(balance.verdict)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(verdictColor.opacity(0.2)))
                        .foregroundStyle(verdictColor)
                }

                if balance.hasEnoughData {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.accent)
                                .frame(width: max(3, geo.size.width * balance.easyRatio))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.amber)
                                .frame(width: max(3, geo.size.width * balance.moderateRatio))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.accentWarm)
                                .frame(width: max(3, geo.size.width * balance.hardRatio))
                        }
                    }
                    .frame(height: 16)

                    HStack {
                        legend("輕鬆", balance.easyRatio, Theme.accent)
                        legend("中等", balance.moderateRatio, Theme.amber)
                        legend("高強度", balance.hardRatio, Theme.accentWarm)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "target")
                            .font(.caption2)
                            .foregroundStyle(Theme.mint)
                        Text("參考基準：輕鬆約 80%、高強度約 20%")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    EmptyStateView(systemImage: "scalemass",
                                   title: "資料還不夠",
                                   message: "近 90 天需要至少 5 次有配速或強度的訓練。",
                                   tint: Theme.amber,
                                   compact: true)
                }

                Text(balance.advice)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var verdictColor: Color {
        switch balance.easyRatio {
        case ..<0.55: return Theme.accentWarm
        case ..<0.72: return Theme.amber
        case ..<0.88: return Theme.mint
        default: return Theme.accent
        }
    }

    private func legend(_ title: String, _ ratio: Double, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(String(format: "%.0f%%", ratio * 100))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
