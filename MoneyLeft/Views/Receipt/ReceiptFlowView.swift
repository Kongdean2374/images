import SwiftUI
import SwiftData
import UIKit

/// 收據辨識流程：來源選擇（拍照 / 相簿）→ 批次 OCR → 逐筆確認。
struct ReceiptFlowView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var pendingSource: TransactionSource = .ocrPhotoLibrary
    @State private var isScanning = false
    @State private var scanProgress: (done: Int, total: Int) = (0, 0)
    @State private var results: [ReceiptScanResult] = []
    @State private var currentIndex = 0
    @State private var savedCount = 0

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isScanning {
                    scanningView
                } else if currentIndex < results.count {
                    confirmView
                } else if !results.isEmpty {
                    finishedView
                } else {
                    sourceChooser
                }
            }
            .navigationTitle("收據辨識")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                Task { await scan([image]) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showingLibrary) {
            PhotoPicker(selectionLimit: 10) { images in
                Task { await scan(images) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - 來源選擇

    private var sourceChooser: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("辨識全程在這台裝置上完成")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                Button {
                    pendingSource = .ocrCamera
                    showingCamera = true
                } label: {
                    sourceLabel("拍照辨識", subtitle: cameraAvailable ? "用相機直接拍收據" : "此裝置目前無法使用相機", icon: "camera.fill")
                }
                .disabled(!cameraAvailable)

                Button {
                    pendingSource = .ocrPhotoLibrary
                    showingLibrary = true
                } label: {
                    sourceLabel("從相簿選擇", subtitle: "可一次選多張，批次辨識", icon: "photo.on.rectangle.angled")
                }
            }
            .padding(.horizontal)

            Text("辨識結果一律會先讓你確認，不會直接寫入。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .padding()
    }

    private func sourceLabel(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.primary)
    }

    // MARK: - 辨識中

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("辨識中… \(scanProgress.done)/\(scanProgress.total)")
                .font(.subheadline)
                .monospacedDigit()
            Text("Vision 本地辨識，不會上傳任何照片")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 逐筆確認

    private var confirmView: some View {
        let result = results[currentIndex]
        return VStack(spacing: 0) {
            HStack {
                Text("第 \(currentIndex + 1) / \(results.count) 張")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("跳過這張") { advance() }
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))

            if result.isFromInvoiceQR {
                Label("已掃到電子發票 QR，金額與日期直接從發票取得", systemImage: "qrcode.viewfinder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: "#34C759"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }

            if result.failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
                    Text("這張沒辨識到文字").font(.subheadline)
                    Text("可以直接手動填寫，或跳過").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 24)
            }

            ExpenseEditorView(
                prefill: .init(
                    amount: result.amount,
                    date: result.date,
                    merchant: result.merchant,
                    imageData: imageData(for: result),
                    source: result.sourceType,
                    rawLines: result.lines,
                    note: result.invoiceNumber.map { "發票 \($0)" }
                ),
                onSaved: {
                    savedCount += 1
                    advance()
                },
                embedded: true
            )
            .id(result.id)
        }
    }

    private var finishedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(hex: "#34C759"))
            Text("完成，共記下 \(savedCount) 筆")
                .font(.headline)
            Button("再辨識一批") {
                results = []
                currentIndex = 0
                savedCount = 0
            }
            .buttonStyle(.bordered)
            Button("關閉") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Actions

    private func scan(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        await MainActor.run {
            isScanning = true
            scanProgress = (0, images.count)
            results = []
            currentIndex = 0
            savedCount = 0
        }
        var collected: [ReceiptScanResult] = []
        for image in images {
            let scaled = image.downscaled()
            var result = await ReceiptScanner.scan(scaled)
            result.sourceType = pendingSource
            collected.append(result)
            await MainActor.run { scanProgress.done = collected.count }
        }
        await MainActor.run {
            results = collected
            isScanning = false
        }
    }

    private func imageData(for result: ReceiptScanResult) -> Data? {
        guard AppSettings.keepReceiptImage else { return nil }
        return result.image.jpegData(compressionQuality: 0.7)
    }

    private func advance() {
        if currentIndex + 1 <= results.count {
            currentIndex += 1
        }
    }
}
