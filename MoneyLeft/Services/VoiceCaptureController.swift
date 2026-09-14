import Foundation
import Speech
import AVFoundation

/// 語音擷取：全程使用裝置端辨識，音檔不落地、不上傳。
@MainActor
final class VoiceCaptureController: ObservableObject {

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case finished
        case denied(String)
        case unsupported(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var level: Double = 0

    /// 講完停頓多久算結束
    var silenceThreshold: TimeInterval = 1.4

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceWorkItem: DispatchWorkItem?
    private var onFinish: ((String) -> Void)?

    var isRecording: Bool { state == .recording }

    /// 裝置端（離線）辨識是否可用。不可用時我們不會改走網路辨識。
    var onDeviceAvailable: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    // MARK: - 開始 / 結束

    func start(onFinish: @escaping (String) -> Void) {
        self.onFinish = onFinish
        transcript = ""
        state = .preparing

        guard let recognizer, recognizer.isAvailable else {
            state = .unsupported("這台裝置的中文語音辨識目前不可用。")
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard let self else { return }
                switch authStatus {
                case .authorized:
                    self.requestMicrophone()
                case .denied, .restricted:
                    self.state = .denied("語音辨識權限被拒絕，請到 設定 → MoneyLeft 開啟。")
                case .notDetermined:
                    self.state = .denied("尚未取得語音辨識權限。")
                @unknown default:
                    self.state = .denied("無法取得語音辨識權限。")
                }
            }
        }
    }

    private func requestMicrophone() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.state = .denied("麥克風權限被拒絕，請到 設定 → MoneyLeft 開啟。")
                    return
                }
                self.beginSession()
            }
        }
    }

    private func beginSession() {
        guard onDeviceAvailable else {
            state = .unsupported(
                "這台裝置還沒下載中文離線聽寫。請到 設定 → 一般 → 鍵盤 → 啟用聽寫（並確認語言含中文），下載完再回來。\n\nMoneyLeft 不會把你的語音送到任何伺服器，所以沒有離線能力時不提供語音記帳。"
            )
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            if #available(iOS 16.0, *) { request.addsPunctuation = false }
            self.request = request

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
                self?.updateLevel(from: buffer)
            }

            engine.prepare()
            try engine.start()

            task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        self.scheduleSilenceStop()
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.finish()
                    }
                }
            }

            state = .recording
            scheduleSilenceStop()
        } catch {
            state = .unsupported("無法開始錄音：\(error.localizedDescription)")
        }
    }

    /// 手動停止
    func stop() {
        finish()
    }

    func cancel() {
        silenceWorkItem?.cancel()
        teardown()
        state = .idle
        transcript = ""
        onFinish = nil
    }

    private func finish() {
        guard state == .recording || state == .preparing else { return }
        silenceWorkItem?.cancel()
        teardown()
        state = .finished
        let text = transcript
        let callback = onFinish
        onFinish = nil
        callback?(text)
    }

    private func teardown() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        level = 0
    }

    // MARK: - 靜音偵測與音量

    private func scheduleSilenceStop() {
        silenceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .recording, !self.transcript.isEmpty else { return }
                self.finish()
            }
        }
        silenceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceThreshold, execute: item)
    }

    private nonisolated func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for index in 0..<frames { sum += channel[index] * channel[index] }
        let rms = sqrt(sum / Float(frames))
        let normalized = Double(min(max(rms * 12, 0), 1))
        Task { @MainActor [weak self] in
            self?.level = normalized
        }
    }
}
