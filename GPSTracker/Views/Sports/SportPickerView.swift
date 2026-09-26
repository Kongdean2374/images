import SwiftUI

/// 運動項目目錄：依分類瀏覽或搜尋，選好後決定要用 GPS 記錄還是計時記錄。
struct SportPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var location = LocationManager.shared
    @StateObject private var customStore = CustomSportStore.shared

    @State private var search = ""
    @State private var launchDiscipline: Discipline?
    @State private var showEditor = false
    @State private var editingSport: SportKind?
    @State private var category: SportCategory?
    @State private var selected: SportKind?
    @State private var launchMode: WorkoutType?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var results: [SportKind] {
        var list = search.isEmpty ? SportCatalog.visible : SportCatalog.search(search)
        if let category {
            list = list.filter { $0.category == category }
        }
        return list.filter { !$0.isCustom }
    }

    private var customSports: [SportKind] {
        var list = customStore.sports
        if let category { list = list.filter { $0.category == category } }
        if !search.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if search.isEmpty && category == nil && !SportCatalog.recent.isEmpty {
                    section("最近使用") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(SportCatalog.recent) { sport in
                                tile(sport)
                            }
                        }
                    }
                }

                categoryBar

                if !customSports.isEmpty {
                    section("我的運動") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(customSports) { sport in
                                tile(sport)
                            }
                        }
                    }
                }

                addCustomButton

                section(category?.displayName ?? (search.isEmpty ? "常見項目" : "搜尋結果")) {
                    if results.isEmpty {
                        EmptyStateView(systemImage: "magnifyingglass",
                                       title: "找不到符合的項目",
                                       message: "換個關鍵字，或用「其他運動」自行記錄。",
                                       compact: true)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(results) { sport in
                                tile(sport)
                            }
                        }
                    }
                }

                Text("只列常見項目，其餘請用「新增自訂運動」自己加，\n這樣清單才不會塞滿你永遠用不到的東西。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("選擇運動項目")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜尋運動項目")
        .sheet(item: $selected) { sport in
            startSheet(sport)
        }
        .fullScreenCover(item: $launchMode) { mode in
            if mode == .gpsActivity, let sport = pendingSport {
                GPSTrackingView(type: .gpsActivity, sport: sport)
            } else if let sport = pendingSport {
                TimedActivityView(sport: sport)
            }
        }
        .fullScreenCover(item: $launchDiscipline) { discipline in
            DisciplineHostView(discipline: discipline)
        }
        .sheet(isPresented: $showEditor) {
            CustomSportEditor { created in
                selected = created
            }
        }
        .sheet(item: $editingSport) { sport in
            CustomSportEditor(editing: sport) { _ in }
        }
    }

    @State private var pendingSport: SportKind?

    private var addCustomButton: some View {
        Button {
            showEditor = true
            CueService.shared.impact(.soft)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.violet.opacity(0.18))
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.violet)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新增自訂運動")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("取個名字、選圖示與強度，就能跟內建項目一樣記錄")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.violet.opacity(0.35), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", icon: "square.grid.2x2", selected: category == nil) { category = nil }
                ForEach(SportCategory.allCases) { item in
                    chip(title: item.displayName, icon: item.icon, selected: category == item) {
                        category = category == item ? nil : item
                    }
                }
            }
        }
    }

    private func chip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? Theme.accent.opacity(0.3) : Color.white.opacity(0.07)))
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func tile(_ sport: SportKind) -> some View {
        Button {
            selected = sport
            CueService.shared.impact(.soft)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.color(for: sport.category).opacity(0.18))
                    Image(systemName: sport.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.color(for: sport.category))
                }
                .frame(width: 40, height: 40)
                Text(sport.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Image(systemName: sport.tracksDistance ? "location.fill" : "timer")
                        .font(.system(size: 9))
                    Text(sport.tracksDistance ? "可 GPS" : "計時")
                    Text("・MET \(String(format: "%.1f", sport.met))")
                    if sport.isCustom {
                        Text("・自訂")
                            .foregroundStyle(Theme.violet)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
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
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sport.name)
        .accessibilityHint(sport.tracksDistance ? "可用 GPS 記錄或計時" : "以計時記錄")
        .contextMenu {
            if sport.isCustom {
                Button {
                    editingSport = sport
                } label: {
                    Label("編輯", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    customStore.remove(sport)
                } label: {
                    Label("刪除", systemImage: "trash")
                }
            }
        }
    }

    private func startSheet(_ sport: SportKind) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.color(for: sport.category).opacity(0.2))
                Image(systemName: sport.icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.color(for: sport.category))
            }
            .frame(width: 78, height: 78)
            .padding(.top, 26)

            Text(sport.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(sport.category.displayName)・MET \(String(format: "%.1f", sport.met))")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 12) {
                if let discipline = DisciplineCatalog.discipline(forSportID: sport.id) {
                    Button {
                        SportCatalog.markUsed(sport)
                        selected = nil
                        launchDiscipline = discipline
                    } label: {
                        Label("進入「\(discipline.name)」專屬模式", systemImage: discipline.icon)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Text("這個項目有專屬畫面，會自動依定位狀況選擇記錄方式。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                } else if sport.tracksDistance {
                    Button {
                        guard location.canRecordGPS else {
                            location.requestPermission()
                            return
                        }
                        SportCatalog.markUsed(sport)
                        pendingSport = sport
                        selected = nil
                        launchMode = .gpsActivity
                    } label: {
                        Label(location.canRecordGPS ? "用 GPS 記錄軌跡" : "需要定位權限才能用 GPS",
                              systemImage: location.canRecordGPS ? "map.fill" : "location.slash.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .opacity(location.canRecordGPS ? 1 : 0.55)
                }

                if DisciplineCatalog.discipline(forSportID: sport.id) == nil {
                    Button {
                        SportCatalog.markUsed(sport)
                        pendingSport = sport
                        selected = nil
                        launchMode = .timedActivity
                    } label: {
                        Label("計時記錄（不需定位）", systemImage: "stopwatch.fill")
                    }
                    .buttonStyle(sport.tracksDistance ? AnyButtonStyleWrapper(SecondaryButtonStyle())
                                                      : AnyButtonStyleWrapper(PrimaryButtonStyle()))
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .screenBackground()
        .presentationDetents([.height(sport.tracksDistance ? 400 : 330)])
    }
}

/// 讓兩種按鈕樣式能在同一個位置切換
struct AnyButtonStyleWrapper: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}
