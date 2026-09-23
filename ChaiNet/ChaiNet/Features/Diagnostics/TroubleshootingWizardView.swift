import SwiftUI
import ChaiNetCore

/// Symptom-driven test selection: only what is needed to diagnose the reported problem.
struct TroubleshootingWizardView: View {
    @State private var symptoms: Set<TroubleshootingSymptom> = []
    @State private var session: DiagnosticSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("你遇到什麼問題？（可複選）").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(TroubleshootingSymptom.allCases) { s in
                        let on = symptoms.contains(s)
                        Button {
                            withAnimation(.snappy) { if on { symptoms.remove(s) } else { symptoms.insert(s) } }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: s.symbolName).font(.title3).foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                                Text(s.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                Text(s.detail).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                            .padding(12)
                            .background(on ? Theme.accent.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(on ? Theme.accent : Theme.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !symptoms.isEmpty { plan }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("疑難排解精靈")
        .navigationDestination(item: $session) { s in
            DiagnosticSessionView(session: s, autoRun: TroubleshootingPlanner.profile(for: symptoms).items)
        }
    }

    private var plan: some View {
        let profile = TroubleshootingPlanner.profile(for: symptoms)
        let manual = TroubleshootingPlanner.manualSteps(for: symptoms)
        return VStack(alignment: .leading, spacing: 10) {
            Text("將執行的測試（\(profile.items.count) 項）").font(.headline)
            FlowText(items: profile.orderedItems.map(\.displayName))
            if !manual.isEmpty {
                Text("之後建議手動加入：").font(.subheadline.weight(.semibold))
                ForEach(manual, id: \.self) { Text("• \($0.title)").font(.caption).foregroundStyle(Theme.textSecondary) }
            }
            PrimaryButton(title: "開始診斷", symbol: "play.fill") {
                let first = symptoms.count == 1 ? symptoms.first : nil
                session = DiagnosticSession(title: "\(profile.name) · \(Format.date(Date()))", symptom: first)
            }
        }
        .cardStyle()
    }
}

/// Wrapping chips.
struct FlowText: View {
    let items: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(items.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
