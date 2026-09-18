import SwiftUI
import Charts

/// 標準距離最佳成績
struct BestEffortsCard: View {
    let efforts: [BestEffort]
    var unit: DistanceUnit = .metric
    var showsDate = true

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    GlossaryHeader(title: "最佳分段",
                                   termID: "bestEfforts",
                                   icon: "bolt.badge.clock")
                    Spacer()
                }
                if efforts.isEmpty {
                    EmptyStateView(systemImage: "bolt.badge.clock",
                                   title: "還沒有可比較的軌跡",
                                   message: "有 GPS 軌跡的紀錄才能算出各距離的最快一段。",
                                   tint: Theme.amber,
                                   compact: true)
                } else {
                    ForEach(efforts) { effort in
                        HStack(spacing: 10) {
                            Text(effort.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 92, alignment: .leading)
                            Text(Fmt.duration(effort.duration))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Text(Fmt.pace(effort.pace, unit: unit))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.mint)
                            if showsDate {
                                Text(Fmt.date(effort.date))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 84, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 3)
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
        }
    }
}

/// 配速區間分佈
struct PaceZoneCard: View {
    let slices: [PaceZoneSlice]
    var averagePace: Double?
    var unit: DistanceUnit = .metric

    private var total: TimeInterval {
        max(1, slices.reduce(0) { $0 + $1.seconds })
    }

    private func color(_ index: Int) -> Color {
        switch index {
        case 0: return Theme.accent.opacity(0.7)
        case 1: return Theme.accent
        case 2: return Theme.mint
        case 3: return Theme.amber
        default: return Theme.accentWarm
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("配速區間", systemImage: "chart.bar.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let averagePace {
                        Text("基準 \(Fmt.pace(averagePace, unit: unit))")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(slices) { slice in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color(slice.index))
                                .frame(width: max(2, geo.size.width * slice.seconds / total))
                        }
                    }
                }
                .frame(height: 14)

                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        Circle().fill(color(slice.index)).frame(width: 9, height: 9)
                        Text(slice.label)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(Fmt.duration(slice.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                        Text(String(format: "%.0f%%", slice.seconds / total * 100))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(color(slice.index))
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                Text("以這次的平均配速為基準切成五區，看得出整場是穩定跑還是忽快忽慢。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// 每週回顧（本週 vs 上週）
struct WeeklyRecapCard: View {
    let thisWeek: (distance: Double, duration: TimeInterval, count: Int)
    let lastWeek: (distance: Double, duration: TimeInterval, count: Int)
    var unit: DistanceUnit = .metric

    private func delta(_ current: Double, _ previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("每週回顧", systemImage: "calendar.badge.clock")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("本週 vs 上週")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 10) {
                    recapTile("里程",
                              Fmt.distanceValue(thisWeek.distance, unit: unit),
                              delta(thisWeek.distance, lastWeek.distance),
                              Theme.accent)
                    recapTile("時間",
                              Fmt.duration(thisWeek.duration),
                              delta(thisWeek.duration, lastWeek.duration),
                              Theme.mint)
                    recapTile("次數",
                              "\(thisWeek.count)",
                              delta(Double(thisWeek.count), Double(lastWeek.count)),
                              Theme.amber)
                }
            }
        }
    }

    private func recapTile(_ title: String, _ value: String, _ change: Double?, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            if let change {
                HStack(spacing: 2) {
                    Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(String(format: "%.0f%%", abs(change) * 100))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(change >= 0 ? Theme.mint : Theme.textSecondary)
            } else {
                Text("新的一週")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}
