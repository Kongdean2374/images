import Foundation
import AVFoundation
import UIKit

/// 步頻節拍器：用聲音＋震動打拍子，訓練固定步頻。
/// 不需要定位，室內、營區都能用。
final class CadenceMetronome: ObservableObject {
    @Published var bpm: Double = 170 {
        didSet {
            UserDefaults.standard.set(bpm, forKey: "metronomeBPM")
            if isRunning { restartTimer() }
        }
    }
    @Published private(set) var isRunning = false
    @Published var useSound = true
    @Published var useHaptics = true

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let generator = UIImpactFeedbackGenerator(style: .rigid)

    init() {
        let stored = UserDefaults.standard.double(forKey: "metronomeBPM")
        if stored >= 100 && stored <= 220 { bpm = stored }
        preparePlayer()
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        CueService.shared.configureAudioSession()
        generator.prepare()
        restartTimer()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = 60.0 / max(40, min(240, bpm))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        if useSound {
            player?.currentTime = 0
            player?.play()
        }
        if useHaptics {
            generator.impactOccurred(intensity: 0.7)
        }
    }

    // MARK: 產生點擊音（不需要外部音檔）

    private func preparePlayer() {
        guard let url = Self.clickFileURL() else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.9
        player?.prepareToPlay()
    }

    private static func clickFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metronome-click.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = makeClickWAV() else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 產生 25ms、1200Hz 帶衰減包絡的點擊音
    private static func makeClickWAV() -> Data? {
        let sampleRate = 44100.0
        let duration = 0.025
        let frequency = 1200.0
        let frameCount = Int(sampleRate * duration)

        var samples = [Int16]()
        samples.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 160)
            let value = sin(2 * .pi * frequency * t) * envelope
            samples.append(Int16(max(-1, min(1, value)) * 26000))
        }

        var data = Data()
        let byteRate = Int(sampleRate) * 2
        let dataSize = samples.count * 2

        func append(_ string: String) {
            data.append(contentsOf: Array(string.utf8))
        }
        func append32(_ value: Int) {
            let raw = UInt32(value).littleEndian
            withUnsafeBytes(of: raw) { buffer in
                data.append(contentsOf: buffer)
            }
        }
        func append16(_ value: Int) {
            let raw = UInt16(value).littleEndian
            withUnsafeBytes(of: raw) { buffer in
                data.append(contentsOf: buffer)
            }
        }

        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)            // PCM header size
        append16(1)             // PCM
        append16(1)             // mono
        append32(Int(sampleRate))
        append32(byteRate)
        append16(2)             // block align
        append16(16)            // bits per sample
        append("data")
        append32(dataSize)
        for sample in samples {
            let raw = sample.littleEndian
            withUnsafeBytes(of: raw) { buffer in
                data.append(contentsOf: buffer)
            }
        }
        return data
    }
}
