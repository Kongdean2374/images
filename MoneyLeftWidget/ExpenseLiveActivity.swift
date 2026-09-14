import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

/// 動態島 / 鎖定畫面的記帳介面（計劃書 §1-2）
struct ExpenseLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExpenseActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("記帳中").font(.caption2).foregroundStyle(.secondary)
                        Label(context.state.categoryName, systemImage: context.state.categoryIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(hex: context.state.categoryColorHex))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Money.string(context.state.amount))
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("剩 \(Money.compact(max(context.state.remaining, 0)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if context.state.savedCount > 0 {
                        Text("已記 \(context.state.savedCount) 筆 · \(Money.string(context.state.savedTotal))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(context.attributes.quickAmounts, id: \.self) { value in
                                Button(intent: AdjustLiveAmountIntent(delta: Double(value))) {
                                    Text("+\(value)")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            Button(intent: ResetLiveAmountIntent()) {
                                Image(systemName: "delete.left")
                            }
                            .buttonStyle(.bordered)
                        }

                        HStack(spacing: 6) {
                            ForEach(context.attributes.quickCategories) { category in
                                Button(intent: SelectLiveCategoryIntent(
                                    categoryName: category.name,
                                    iconName: category.iconName,
                                    colorHex: category.colorHex
                                )) {
                                    Image(systemName: category.iconName)
                                        .font(.caption)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(category.name == context.state.categoryName
                                      ? Color(hex: category.colorHex)
                                      : Color.gray.opacity(0.4))
                            }
                        }

                        HStack(spacing: 8) {
                            Button(intent: EndLiveActivityIntent()) {
                                Text("結束").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(.gray)

                            Button(intent: SaveLiveExpenseIntent()) {
                                Label("記下來", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(hex: "#0A84FF"))
                            .disabled(context.state.amount <= 0)
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: context.state.categoryIcon)
                    .foregroundStyle(Color(hex: context.state.categoryColorHex))
            } compactTrailing: {
                Text(context.state.amount > 0 ? Money.string(context.state.amount) : Money.compact(max(context.state.remaining, 0)))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(Color(hex: "#0A84FF"))
            }
            .widgetURL(URL(string: "\(AppGroup.urlScheme)://add"))
            .keylineTint(Color(hex: "#0A84FF"))
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<ExpenseActivityAttributes>

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label(context.state.categoryName, systemImage: context.state.categoryIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: context.state.categoryColorHex))
                Spacer()
                Text(Money.string(context.state.amount))
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                ForEach(context.attributes.quickAmounts, id: \.self) { value in
                    Button(intent: AdjustLiveAmountIntent(delta: Double(value))) {
                        Text("+\(value)").font(.caption.weight(.bold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(intent: ResetLiveAmountIntent()) {
                    Image(systemName: "delete.left")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 6) {
                ForEach(context.attributes.quickCategories) { category in
                    Button(intent: SelectLiveCategoryIntent(
                        categoryName: category.name,
                        iconName: category.iconName,
                        colorHex: category.colorHex
                    )) {
                        Image(systemName: category.iconName).font(.caption).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(category.name == context.state.categoryName ? Color(hex: category.colorHex) : Color.gray.opacity(0.4))
                }
            }

            HStack(spacing: 8) {
                Button(intent: EndLiveActivityIntent()) {
                    Text("結束").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.gray)

                Button(intent: SaveLiveExpenseIntent()) {
                    Label("記下來", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#0A84FF"))
                .disabled(context.state.amount <= 0)
            }

            HStack {
                if context.state.savedCount > 0 {
                    Text("已記 \(context.state.savedCount) 筆")
                }
                Spacer()
                Text("本月剩 \(Money.string(max(context.state.remaining, 0)))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}
