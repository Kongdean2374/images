import Foundation
import Vision
import UIKit

/// 收據辨識結果（進「確認畫面」前的建議值，絕不自動寫入）。
struct ReceiptScanResult: Identifiable {
    let id = UUID()
    var image: UIImage
    var amount: Double?
    var date: Date?
    var merchant: String?
    var lines: [String] = []
    var failed: Bool = false
    var sourceType: TransactionSource = .ocrPhotoLibrary
    /// 電子發票 QR 解出來的號碼（有值代表金額是掃 QR 拿到的，準度很高）
    var invoiceNumber: String?
    var isFromInvoiceQR: Bool = false
}

/// Vision Framework 本地 OCR，完全不連網（計劃書 §2-3）。
enum ReceiptScanner {

    static let totalKeywords = ["總計", "合計", "總金額", "應收", "實收", "應付", "消費金額", "本次消費", "金額", "total", "amount"]
    static let weakKeywords = ["小計", "subtotal"]

    static func scan(_ image: UIImage) async -> ReceiptScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: performScan(image))
            }
        }
    }

    static func scan(images: [UIImage]) async -> [ReceiptScanResult] {
        var results: [ReceiptScanResult] = []
        for image in images {
            results.append(await scan(image))
        }
        return results
    }

    // MARK: - Vision

    private static func performScan(_ image: UIImage) -> ReceiptScanResult {
        guard let cgImage = image.cgImage else {
            return ReceiptScanResult(image: image, failed: true)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hant", "en-US"]

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return ReceiptScanResult(image: image, failed: true)
        }

        // 先試電子發票 QR：有掃到就用它的金額與日期，準度遠高於 OCR 猜「總計」
        let invoice = InvoiceQRParser.detect(in: cgImage, orientation: orientation)

        let observations = request.results ?? []
        // Vision 的座標原點在左下，minY 越大代表越上面。
        let sorted = observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        let lines = sorted.compactMap { $0.topCandidates(1).first?.string }

        return ReceiptScanResult(
            image: image,
            amount: invoice?.total ?? guessAmount(from: lines),
            date: invoice?.date ?? guessDate(from: lines),
            merchant: guessMerchant(from: sorted),
            lines: lines,
            failed: lines.isEmpty && invoice == nil,
            invoiceNumber: invoice?.invoiceNumber,
            isFromInvoiceQR: invoice != nil
        )
    }

    // MARK: - 金額

    static func guessAmount(from lines: [String]) -> Double? {
        var strongCandidates: [Double] = []
        var weakCandidates: [Double] = []

        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            let hasStrong = totalKeywords.contains { lower.contains($0.lowercased()) }
            let hasWeak = weakKeywords.contains { lower.contains($0.lowercased()) }
            guard hasStrong || hasWeak else { continue }

            var numbers = extractNumbers(from: line)
            // 關鍵字那行沒數字時，往下一行找（收據常見換行排版）
            if numbers.isEmpty, index + 1 < lines.count {
                numbers = extractNumbers(from: lines[index + 1])
            }
            guard let value = numbers.max() else { continue }
            if hasStrong { strongCandidates.append(value) } else { weakCandidates.append(value) }
        }

        if let best = strongCandidates.max() { return best }
        if let best = weakCandidates.max() { return best }

        // 都找不到關鍵字 → 退而求其次，取整張收據裡最大的合理數字
        let all = lines.flatMap { extractNumbers(from: $0) }.filter { $0 < 1_000_000 }
        return all.max()
    }

    static func extractNumbers(from line: String) -> [Double] {
        let pattern = "[0-9]+(?:,[0-9]{3})*(?:\\.[0-9]{1,2})?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard let r = Range(match.range, in: line) else { return nil }
            let text = line[r].replacingOccurrences(of: ",", with: "")
            guard let value = Double(text) else { return nil }
            // 過濾掉發票號碼、統編、日期這類「看起來不像金額」的數字
            if text.count >= 8 { return nil }
            if value == 0 { return nil }
            return value
        }
    }

    // MARK: - 日期

    static func guessDate(from lines: [String]) -> Date? {
        let patterns = [
            "([0-9]{4})[/.\\-年]\\s?([0-9]{1,2})[/.\\-月]\\s?([0-9]{1,2})",
            "([0-9]{2,3})[/.\\-]([0-9]{1,2})[/.\\-]([0-9]{1,2})"
        ]
        for line in lines {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 4 else { continue }
                let parts: [Int] = (1...3).compactMap { idx in
                    guard let r = Range(match.range(at: idx), in: line) else { return nil }
                    return Int(line[r])
                }
                guard parts.count == 3 else { continue }
                var year = parts[0]
                if year < 1911 { year += 1911 }        // 民國年
                if year < 100 { year += 2000 }
                let month = parts[1], day = parts[2]
                guard (1...12).contains(month), (1...31).contains(day) else { continue }
                var components = DateComponents()
                components.year = year
                components.month = month
                components.day = day
                components.hour = 12
                if let date = DateHelper.calendar.date(from: components),
                   date < Date().addingTimeInterval(86400 * 2),
                   date > Date().addingTimeInterval(-86400 * 365 * 3) {
                    return date
                }
            }
        }
        return nil
    }

    // MARK: - 店名

    private static func guessMerchant(from observations: [VNRecognizedTextObservation]) -> String? {
        let candidates = observations.prefix(6).compactMap { observation -> (String, CGFloat)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return nil }
            // 排除整行都是數字／符號的（發票號碼、日期）
            let digits = trimmed.filter { $0.isNumber || $0 == "-" || $0 == "/" }.count
            guard Double(digits) / Double(trimmed.count) < 0.5 else { return nil }
            return (trimmed, observation.boundingBox.height)
        }
        // 最上面幾行裡，字體最大的那行最可能是店名
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
