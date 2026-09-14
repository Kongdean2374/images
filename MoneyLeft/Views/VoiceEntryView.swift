import SwiftUI
import SwiftData

/// 語音記帳：講一句話 → 自動解析 → 直接打開確認介面（填好但不自動送出）。
struct VoiceEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = VoiceCaptureController()
    @Query private var learned: [PhraseMapping]

    @State private var entries: [ParsedEntry] = []
    @State private var currentIndex = 0
    @State private var savedCount = 0
    @State private var spokenText = ""
    @State private var parseFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if !entries.isEmpty && currentIndex < entries.count {
                    confirmStage
                } else if !entries.isEmpty {
                    doneStage
                } else {
                    recordStage
                }
            }
            .navigationTitle("語音記帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") {
                        capture.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: beginRecording)
        .onDisappear { capture.cancel() }
    }

    // MARK: - 錄音

    private var recordStage: some View {
        VStack(spacing: 20) {
            Spacer()
            micVisual
            statusArea
            Spacer()
            controlButton
            Text("辨識全程在這台裝置上完成，語音不會離開手機")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }

    private var micVisual: some View {
        ZStack {
            Circle()
                .stroke(Theme.accent.opacity(0.18), lineWidth: 2)
                .frame(width: 150 + CGFloat(capture.level) * 40)
            Circle()
                .stroke(Theme.accent.opacity(0.12), lineWidth: 2)
                .frame(width: 200 + CGFloat(capture.level) * 60)
            Circle()
                .fill(Theme.accent)
                .frame(width: 96 + CGFloat(capture.level) * 24)
            Image(systemName: "mic.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(height: 240)
        .animation(.easeOut(duration: 0.2), value: capture.level)
    }

    @ViewBuilder
    private var statusArea: some View {
        switch capture.state {
        case .recording:
            recordingText
        case .preparing:
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("準備中…").font(.subheadline).foregroundStyle(.secondary)
            }
        case .denied(let message):
            warningText(message)
        case .unsupported(let message):
            warningText(message)
        case .finished:
            finishedText
        case .idle:
            Text("準備開始").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var recordingText: some View {
        VStack(spacing: 8) {
            Text(capture.transcript.isEmpty ? "請說話…例如「早餐五十」" : capture.transcript)
                .font(.title3.weight(.medium))
                .foregroundStyle(capture.transcript.isEmpty ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("講完停頓一下就會自動結束")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var finishedText: some View {
        if parseFailed {
            VStack(spacing: 8) {
                Text("「\(spokenText)」").font(.subheadline)
                Text("沒聽出金額，可以再試一次，或直接手動輸入")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
        }
    }

    private func warningText(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        if capture.isRecording {
            Button {
                capture.stop()
            } label: {
                Label("講完了", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        } else {
            Button {
                parseFailed = false
                beginRecording()
            } label: {
                Label("重新錄音", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
    }

    // MARK: - 確認

    private var confirmStage: some View {
        let entry = entries[currentIndex]
        return VStack(spacing: 0) {
            if entries.count > 1 {
                HStack {
                    Text("第 \(currentIndex + 1) / \(entries.count) 筆")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("跳過") { advance() }.font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))
            }

            ExpenseEditorView(
                prefill: .init(
                    amount: entry.amount,
                    date: entry.date,
                    merchant: nil,
                    imageData: nil,
                    source: .siri,
                    rawLines: [],
                    categoryName: entry.categoryName,
                    subCategoryName: entry.subCategoryName,
                    emotionName: entry.emotionName,
                    note: nil,
                    confidence: entry.confidence,
                    learningPhrase: VoiceParser.learningPhrase(for: entry.rawText),
                    spokenText: entry.rawText
                ),
                onSaved: {
                    savedCount += 1
                    advance()
                },
                embedded: true
            )
            .id(entry.id)
        }
    }

    private var doneStage: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(hex: "#34C759"))
            Text("完成，共記下 \(savedCount) 筆").font(.headline)
            Button("再講一筆") {
                entries = []
                currentIndex = 0
                savedCount = 0
                beginRecording()
            }
            .buttonStyle(.bordered)
            Button("關閉") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Actions

    private func beginRecording() {
        guard !capture.isRecording else { return }
        entries = []
        currentIndex = 0
        capture.start { text in
            spokenText = text
            let parsed = VoiceParser.parse(text, learned: learned)
            let usable = parsed.filter { $0.isUsable }
            if usable.isEmpty {
                parseFailed = true
            } else {
                entries = usable
            }
        }
    }

    private func advance() {
        currentIndex += 1
    }
}
