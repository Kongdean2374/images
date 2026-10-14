import SwiftUI

struct BackgroundInsightsProgress: View {
    @ObservedObject var store: WorkoutInsightsStore
    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: store.progress)
                Text(store.status).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
