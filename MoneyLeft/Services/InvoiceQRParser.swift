import Foundation
import Vision
import UIKit

/// 台灣電子發票 QR 左碼解析。
/// 左碼前 45 碼的固定格式：
/// `發票字軌(10) + 開立日期民國年月日(7) + 隨機碼(4) + 銷售額未稅(8,16進位) + 總計額含稅(8,16進位) + 買方統編(8)`
/// 有解出來就用它，比 OCR 猜「總計」準得多；解不出來就退回 OCR。
struct InvoiceQRResult {
    var invoiceNumber: String
    var date: Date?
    var total: Double?
    var untaxed: Double?
}

enum InvoiceQRParser {

    /// 掃描整張圖上的 QR，取第一個看起來像電子發票的
    static func detect(in cgImage: CGImage, orientation: CGImagePropertyOrientation) -> InvoiceQRResult? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([request])

        let payloads = (request.results ?? []).compactMap { $0.payloadStringValue }
        for payload in payloads {
            if let result = parse(payload: payload) { return result }
        }
        return nil
    }

    static func parse(payload: String) -> InvoiceQRResult? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(text)
        guard chars.count >= 45 else { return nil }

        func slice(_ from: Int, _ length: Int) -> String {
            String(chars[from..<min(from + length, chars.count)])
        }

        // 發票號碼：兩個英文字母 + 八位數字
        let number = slice(0, 10)
        let letters = number.prefix(2)
        let numbers = number.dropFirst(2)
        guard letters.count == 2,
              letters.allSatisfy({ $0.isLetter }),
              numbers.count == 8,
              numbers.allSatisfy({ $0.isNumber }) else { return nil }

        // 開立日期：民國年(3) + 月(2) + 日(2)
        var date: Date?
        let dateString = slice(10, 7)
        if dateString.allSatisfy({ $0.isNumber }),
           let rocYear = Int(dateString.prefix(3)),
           let month = Int(dateString.dropFirst(3).prefix(2)),
           let day = Int(dateString.dropFirst(5).prefix(2)),
           (1...12).contains(month), (1...31).contains(day), rocYear > 80 {
            var components = DateComponents()
            components.year = rocYear + 1911
            components.month = month
            components.day = day
            components.hour = 12
            date = DateHelper.calendar.date(from: components)
        }

        let untaxed = hexAmount(slice(21, 8))
        let total = hexAmount(slice(29, 8))

        // 兩個金額都解不出來就不算數（避免把別的 QR 當發票）
        guard total != nil || untaxed != nil else { return nil }

        return InvoiceQRResult(
            invoiceNumber: number,
            date: date,
            total: total ?? untaxed,
            untaxed: untaxed
        )
    }

    private static func hexAmount(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard cleaned.count == 8,
              cleaned.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(cleaned, radix: 16) else { return nil }
        let amount = Double(value)
        guard amount > 0, amount < 1_000_000 else { return nil }
        return amount
    }
}
