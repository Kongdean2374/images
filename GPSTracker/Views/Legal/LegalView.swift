import SwiftUI

enum LegalDocument: String, Identifiable {
    case privacy, terms

    var id: String { rawValue }

    var title: String {
        self == .privacy ? "隱私政策" : "使用條款"
    }

    var titleEN: String {
        self == .privacy ? "Privacy Policy" : "Terms of Use"
    }

    var icon: String {
        self == .privacy ? "hand.raised.fill" : "doc.text.fill"
    }

    var zh: [LegalContent.Section] {
        self == .privacy ? LegalContent.privacyZH : LegalContent.termsZH
    }

    var en: [LegalContent.Section] {
        self == .privacy ? LegalContent.privacyEN : LegalContent.termsEN
    }
}

/// 隱私政策 / 使用條款：先中文，往下滑是英文。
struct LegalView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                if document == .privacy { permissionCard }

                documentBlock(title: document.title,
                              subtitle: "版本 \(LegalContent.version)　生效日 \(LegalContent.effectiveDate)",
                              sections: document.zh,
                              flag: "繁體中文")

                Divider()
                    .overlay(Color.white.opacity(0.12))
                    .padding(.vertical, 4)

                documentBlock(title: document.titleEN,
                              subtitle: "Version \(LegalContent.version)　Effective \(LegalContent.effectiveDateEN)",
                              sections: document.en,
                              flag: "English")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .screenBackground()
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Theme.accent.opacity(0.18))
                    Image(systemName: document.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(document.title) / \(document.titleEN)")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("中文在前，英文版請往下滑")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("權限一覽")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                ForEach(LegalContent.permissions) { permission in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().fill(Theme.mint.opacity(0.15))
                            Image(systemName: permission.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.mint)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(permission.purpose)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Text("全部權限皆為選用，拒絕後其餘功能照常運作。")
                    .font(.caption2)
                    .foregroundStyle(Theme.amber)
            }
        }
    }

    private func documentBlock(title: String,
                               subtitle: String,
                               sections: [LegalContent.Section],
                               flag: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(flag)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)

            ForEach(sections) { section in
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.heading)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.accent)
                        Text(section.body)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
