import SwiftUI
import SwiftData

struct SessionRow: View {
    let session: WorkoutSession
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Theme.color(for: session.type).opacity(0.18))
                    Image(systemName: session.type.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.color(for: session.type))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text(Fmt.dateTime(session.startDate))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                        if session.isImported {
                            Text(session.originLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.mint.opacity(0.18)))
                                .foregroundStyle(Theme.mint)
                        }
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(session.totalDistance == nil
                         ? Fmt.duration(session.duration)
                         : Fmt.distance(session.totalDistance, unit: settings.unit))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                    Text(session.totalDistance == nil
                         ? (session.repCount.map { "\($0) 下" } ?? session.type.shortName)
                         : Fmt.pace(session.averagePace, unit: settings.unit))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

struct HistoryListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings

    @State private var filter: WorkoutType?
    @State private var searchText = ""
    @State private var exportURL: URL?
    @State private var showExportShare = false

    private var filtered: [WorkoutSession] {
        sessions.filter { session in
            (filter == nil || session.type == filter)
            && (searchText.isEmpty
                || session.displayTitle.localizedCaseInsensitiveContains(searchText)
                || (session.routeKey ?? "").localizedCaseInsensitiveContains(searchText)
                || (session.notes ?? "").localizedCaseInsensitiveContains(searchText))
        }
    }

    private var grouped: [(key: Date, items: [WorkoutSession])] {
        let calendar = Calendar.current
        var map: [Date: [WorkoutSession]] = [:]
        for session in filtered {
            let key = calendar.date(from: calendar.dateComponents([.year, .month], from: session.startDate)) ?? session.startDate
            map[key, default: []].append(session)
        }
        return map.map { (key: $0.key, items: $0.value) }.sorted { $0.key > $1.key }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
                filterBar
                if filtered.isEmpty {
                    emptyState
                }
                ForEach(grouped, id: \.key) { group in
                    Section {
                        ForEach(group.items) { session in
                            NavigationLink {
                                WorkoutDetailView(session: session)
                            } label: {
                                SessionRow(session: session)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    context.delete(session)
                                    try? context.save()
                                } label: {
                                    Label("刪除", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(Fmt.monthFormatter.string(from: group.key))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(summary(for: group.items))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(Theme.bgTop.opacity(0.92))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("運動紀錄")
        .searchable(text: $searchText, prompt: "搜尋紀錄")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        exportURL = DataExporter.csv(sessions: sessions)
                        showExportShare = exportURL != nil
                    } label: {
                        Label("匯出全部 CSV", systemImage: "tablecells")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showExportShare) {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("分享 CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding()
                .presentationDetents([.height(160)])
            }
        }
    }

    private func summary(for items: [WorkoutSession]) -> String {
        let distance = items.reduce(0.0) { $0 + ($1.totalDistance ?? 0) }
        let duration = items.reduce(0.0) { $0 + $1.duration }
        return "\(items.count) 次・\(Fmt.distance(distance, unit: settings.unit))・\(Fmt.duration(duration))"
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", selected: filter == nil) { filter = nil }
                ForEach(WorkoutType.allCases) { type in
                    chip(title: type.shortName, selected: filter == type) { filter = type }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected ? Theme.accent.opacity(0.3) : Color.white.opacity(0.07)))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            EmptyStateView(systemImage: "figure.run.circle",
                           title: "還沒有紀錄",
                           message: "從「開始」選一個模式，或把健康 App 的歷史訓練匯入進來。")
            NavigationLink {
                HealthImportView()
            } label: {
                Label("一鍵匯入", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.horizontal, 40)
        }
        .padding(.top, 40)
    }
}
