import ActivityKit
import WidgetKit
import SwiftUI

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(context.attributes.modeName, systemImage: context.attributes.symbolName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(WidgetFormat.duration(context.state.elapsed))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.usesDistance
                             ? WidgetFormat.distance(context.state.distance)
                             : "\(context.state.steps) 步")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(WidgetFormat.pace(context.state.pace))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Circle()
                            .fill(context.state.isPaused ? WidgetTheme.amber : WidgetTheme.mint)
                            .frame(width: 7, height: 7)
                        Text(context.state.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if context.state.steps > 0 && context.attributes.usesDistance {
                            Label("\(context.state.steps)", systemImage: "shoeprints.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbolName)
                    .foregroundStyle(WidgetTheme.accent)
            } compactTrailing: {
                Text(WidgetFormat.duration(context.state.elapsed))
                    .font(.caption2)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: context.attributes.symbolName)
                    .foregroundStyle(WidgetTheme.accent)
            }
        }
    }

    private func lockScreenView(context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(WidgetTheme.accent.opacity(0.2))
                Image(systemName: context.attributes.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(WidgetTheme.accent)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.modeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(WidgetFormat.duration(context.state.elapsed))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(context.attributes.usesDistance
                     ? WidgetFormat.distance(context.state.distance)
                     : "\(context.state.steps) 步")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(WidgetFormat.pace(context.state.pace))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(context.state.isPaused ? WidgetTheme.amber : WidgetTheme.mint)
                        .frame(width: 6, height: 6)
                    Text(context.state.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }
}
