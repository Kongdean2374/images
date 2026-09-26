import SwiftUI

/// 名詞旁邊的小問號。點一下開出白話解釋。
struct GlossaryButton: View {
    let termID: String
    var size: CGFloat = 15

    @State private var showing = false

    var body: some View {
        if let term = Glossary.term(termID) {
            Button {
                showing = true
                CueService.shared.impact(.soft)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(term.title)是什麼")
            .sheet(isPresented: $showing) {
                GlossaryDetailView(term: term)
            }
        }
    }
}

/// 標題 + 問號的組合，直接拿來當卡片抬頭用
struct GlossaryHeader: View {
    let title: String
    let termID: String
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
            }
            GlossaryButton(termID: termID, size: 16)
        }
    }
}

/// 單一名詞的說明頁
struct GlossaryDetailView: View {
    let term: GlossaryTerm

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    block(title: "這個數字在算什麼", body: term.howItWorks)
                    if !term.scale.isEmpty { scaleCard }
                    block(title: "實務上怎麼用", body: term.practical)
                    if let caveat = term.caveat { caveatCard(caveat) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .screenBackground()
            .navigationTitle(term.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if !term.fullName.isEmpty {
                    Text(term.fullName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(term.summary)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func block(title: String, body text: String) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(markdown(text))
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scaleCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 11) {
                Text("怎麼讀這個數字")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(Array(term.scale.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 11) {
                        Text(item.range)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(tint(for: index, total: term.scale.count))
                            .frame(width: 104, alignment: .leading)
                        Text(item.meaning)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tint(for index: Int, total: Int) -> Color {
        let palette: [Color] = [Theme.accent, Theme.mint, Theme.amber, Theme.accentWarm, Theme.violet]
        return palette[index % palette.count]
    }

    private func caveatCard(_ text: String) -> some View {
        GlassCard(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("要注意")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.amber)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// 全部名詞一覽，放在設定裡
struct GlossaryListView: View {
    @State private var search = ""

    private var results: [GlossaryTerm] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Glossary.all }
        return Glossary.all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.fullName.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("App 裡每個專有名詞的白話解釋。分析頁上的「?」也會開到這裡。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(results) { term in
                    NavigationLink {
                        GlossaryDetailView(term: term)
                    } label: {
                        GlassCard(padding: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 7) {
                                        Text(term.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        if !term.fullName.isEmpty {
                                            Text(term.fullName)
                                                .font(.caption2)
                                                .foregroundStyle(Theme.accent)
                                                .lineLimit(1)
                                        }
                                    }
                                    Text(term.summary)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("名詞解釋")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜尋名詞")
    }
}
