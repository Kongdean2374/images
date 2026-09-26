import Foundation
import AVFoundation
import MapKit
import UIKit
import CoreLocation

/// 把軌跡回放輸出成一支 MP4：底圖是地圖快照，上面畫出逐漸長出來的路線與數據。
/// 全程在本機算圖，不連網。
@MainActor
final class RouteVideoExporter: ObservableObject {

    enum Stage: Equatable {
        case idle
        case snapshotting
        case rendering(Double)
        case writing
        case done(URL)
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle

    /// 輸出尺寸（直式，適合限動與訊息）
    private let size = CGSize(width: 1080, height: 1920)
    private let fps: Int32 = 60

    private var isCancelled = false

    func cancel() { isCancelled = true }

    func export(session: WorkoutSession,
                unit: DistanceUnit,
                seconds: Double = 12) async {
        isCancelled = false
        let points = session.sortedPoints
        let coordinates = points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard coordinates.count > 2 else {
            stage = .failed("這筆紀錄沒有足夠的軌跡點")
            return
        }

        stage = .snapshotting
        guard let snapshot = await mapSnapshot(for: coordinates) else {
            stage = .failed("地圖底圖產生失敗")
            return
        }

        let totalFrames = Int(seconds * Double(fps))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false

            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                               sourcePixelBufferAttributes: attributes)
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let renderer = FrameRenderer(size: size,
                                         snapshot: snapshot,
                                         coordinates: coordinates,
                                         points: points,
                                         session: session,
                                         unit: unit)

            for frame in 0..<totalFrames {
                if isCancelled {
                    input.markAsFinished()
                    writer.cancelWriting()
                    stage = .idle
                    return
                }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 4_000_000)
                }
                let t = Double(frame) / Double(totalFrames - 1)
                // 前後留一點靜止時間，收尾比較好看
                let eased = Self.ease(t)
                guard let buffer = renderer.buffer(progress: eased, pool: adaptor.pixelBufferPool) else { continue }
                let time = CMTime(value: CMTimeValue(frame), timescale: fps)
                adaptor.append(buffer, withPresentationTime: time)

                if frame % 15 == 0 {
                    stage = .rendering(Double(frame) / Double(totalFrames))
                }
            }

            stage = .writing
            input.markAsFinished()
            await writer.finishWriting()

            if writer.status == .completed {
                stage = .done(url)
            } else {
                stage = .failed(writer.error?.localizedDescription ?? "影片寫入失敗")
            }
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// 前 8% 與後 12% 放慢，中間等速
    private static func ease(_ t: Double) -> Double {
        let head = 0.08, tail = 0.88
        if t < head { return (t / head) * (t / head) * head }
        if t > tail { return tail + (1 - tail) * (1 - pow(1 - (t - tail) / (1 - tail), 2)) }
        return t
    }

    // MARK: 地圖底圖

    private func mapSnapshot(for coordinates: [CLLocationCoordinate2D]) async -> MKMapSnapshotter.Snapshot? {
        guard let region = RouteRenderer.region(for: coordinates, padding: 1.45) else { return nil }
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = 1
        options.mapType = .mutedStandard
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll

        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start { snapshot, _ in
                continuation.resume(returning: snapshot)
            }
        }
    }
}

/// 逐格把畫面畫出來
private final class FrameRenderer {
    private let size: CGSize
    private let snapshot: MKMapSnapshotter.Snapshot
    private let coordinates: [CLLocationCoordinate2D]
    private let points: [RoutePoint]
    private let session: WorkoutSession
    private let unit: DistanceUnit
    private let screenPoints: [CGPoint]
    private let colors: [UIColor]

    init(size: CGSize,
         snapshot: MKMapSnapshotter.Snapshot,
         coordinates: [CLLocationCoordinate2D],
         points: [RoutePoint],
         session: WorkoutSession,
         unit: DistanceUnit) {
        self.size = size
        self.snapshot = snapshot
        self.coordinates = coordinates
        self.points = points
        self.session = session
        self.unit = unit
        self.screenPoints = coordinates.map { snapshot.point(for: $0) }

        // 依速度上色，跟 App 裡的軌跡一致
        let speeds = points.map { $0.speed }
        let valid = speeds.filter { $0 > 0.3 }.sorted()
        let low = valid.isEmpty ? 0 : valid[Int(Double(valid.count) * 0.1)]
        let high = valid.isEmpty ? 1 : valid[min(valid.count - 1, Int(Double(valid.count) * 0.9))]
        let span = max(0.35, high - low)
        self.colors = speeds.map { speed in
            let fraction = max(0, min(1, (speed - low) / span))
            return FrameRenderer.paceColor(fraction)
        }
    }

    private static func paceColor(_ fraction: Double) -> UIColor {
        // 藍 → 綠 → 黃 → 紅
        let stops: [(Double, UIColor)] = [
            (0.0, UIColor(red: 0.23, green: 0.56, blue: 1.00, alpha: 1)),
            (0.4, UIColor(red: 0.18, green: 0.84, blue: 0.63, alpha: 1)),
            (0.72, UIColor(red: 1.00, green: 0.77, blue: 0.26, alpha: 1)),
            (1.0, UIColor(red: 1.00, green: 0.38, blue: 0.26, alpha: 1))
        ]
        for index in 0..<(stops.count - 1) {
            let (p0, c0) = stops[index]
            let (p1, c1) = stops[index + 1]
            if fraction <= p1 {
                let t = (fraction - p0) / max(0.0001, p1 - p0)
                var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
                var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
                c0.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
                c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
                return UIColor(red: r0 + (r1 - r0) * t,
                               green: g0 + (g1 - g0) * t,
                               blue: b0 + (b1 - b0) * t,
                               alpha: 1)
            }
        }
        return stops.last!.1
    }

    func buffer(progress: Double, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: Int(size.width),
                                      height: Int(size.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            return nil
        }

        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(progress: progress, in: context)
        UIGraphicsPopContext()

        return buffer
    }

    private func draw(progress: Double, in context: CGContext) {
        // 底圖
        snapshot.image.draw(in: CGRect(origin: .zero, size: size))

        // 壓暗，讓路線與文字看得清楚
        context.setFillColor(UIColor.black.withAlphaComponent(0.28).cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let exact = progress * Double(screenPoints.count - 1)
        let index = min(screenPoints.count - 1, max(0, Int(exact)))
        let t = exact - Double(index)

        // 未走過的路線（淡淡的預覽）
        context.setLineWidth(6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.16).cgColor)
        context.beginPath()
        context.addLines(between: screenPoints)
        context.strokePath()

        // 已走過的路線，依速度分段上色
        context.setLineWidth(11)
        if index > 0 {
            for i in 0..<index {
                context.setStrokeColor(colors[min(i, colors.count - 1)].cgColor)
                context.beginPath()
                context.move(to: screenPoints[i])
                context.addLine(to: screenPoints[i + 1])
                context.strokePath()
            }
        }

        // 內插出目前的頭部位置
        let head: CGPoint
        if index < screenPoints.count - 1 {
            let a = screenPoints[index], b = screenPoints[index + 1]
            head = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            context.setStrokeColor(colors[min(index, colors.count - 1)].cgColor)
            context.beginPath()
            context.move(to: a)
            context.addLine(to: head)
            context.strokePath()
        } else {
            head = screenPoints[index]
        }

        // 起點
        if let first = screenPoints.first {
            drawDot(at: first, radius: 13, fill: UIColor(red: 0.18, green: 0.84, blue: 0.63, alpha: 1), in: context)
        }
        // 頭部光暈
        context.setFillColor(UIColor(red: 1, green: 0.45, blue: 0.3, alpha: 0.28).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - 34, y: head.y - 34, width: 68, height: 68))
        drawDot(at: head, radius: 16, fill: UIColor(red: 1, green: 0.42, blue: 0.28, alpha: 1), in: context)

        drawOverlay(progress: progress, index: index, in: context)
    }

    private func drawDot(at point: CGPoint, radius: CGFloat, fill: UIColor, in context: CGContext) {
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - radius - 3, y: point.y - radius - 3,
                                       width: (radius + 3) * 2, height: (radius + 3) * 2))
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                       width: radius * 2, height: radius * 2))
    }

    // MARK: 文字資訊

    private func drawOverlay(progress: Double, index: Int, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let title = session.displayTitle
        let dateText = Fmt.dateTime(session.startDate)

        // 上方漸層底
        drawGradient(in: CGRect(x: 0, y: 0, width: size.width, height: 300),
                     topAlpha: 0.72, bottomAlpha: 0, context: context)
        // 下方漸層底
        drawGradient(in: CGRect(x: 0, y: size.height - 460, width: size.width, height: 460),
                     topAlpha: 0, bottomAlpha: 0.82, context: context)

        draw(text: title, at: CGPoint(x: 64, y: 96),
             font: .systemFont(ofSize: 64, weight: .bold), color: .white)
        draw(text: dateText, at: CGPoint(x: 64, y: 176),
             font: .systemFont(ofSize: 34, weight: .medium),
             color: UIColor.white.withAlphaComponent(0.7))

        // 進行中的距離與時間
        let point = points[min(index, points.count - 1)]
        let liveDistance = Fmt.distance(point.distanceFromStart, unit: unit)
        let liveTime = Fmt.duration(point.timestamp.timeIntervalSince(session.startDate))

        let baseY = size.height - 360
        drawStat(title: "距離", value: liveDistance,
                 at: CGPoint(x: 64, y: baseY), context: context)
        drawStat(title: "時間", value: liveTime,
                 at: CGPoint(x: size.width / 2 + 20, y: baseY), context: context)

        let totals = [
            ("總距離", Fmt.distance(session.totalDistance, unit: unit)),
            (session.prefersSpeed ? "平均速度" : "平均配速",
             session.prefersSpeed
                ? String(format: "%.1f km/h", (session.averageSpeed ?? 0) * 3.6)
                : Fmt.pace(session.averagePace, unit: unit)),
            ("熱量", session.calories.map { String(format: "%.0f kcal", $0) } ?? "—")
        ]
        for (offset, item) in totals.enumerated() {
            let x = 64 + CGFloat(offset) * ((size.width - 128) / 3)
            drawStat(title: item.0, value: item.1,
                     at: CGPoint(x: x, y: size.height - 180),
                     titleSize: 26, valueSize: 44, context: context)
        }

        // 進度條
        let barRect = CGRect(x: 64, y: size.height - 70, width: size.width - 128, height: 8)
        context.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
        context.fill(barRect)
        context.setFillColor(UIColor(red: 0.23, green: 0.56, blue: 1, alpha: 1).cgColor)
        context.fill(CGRect(x: barRect.minX, y: barRect.minY,
                            width: barRect.width * CGFloat(progress), height: barRect.height))

        context.restoreGState()
    }

    private func drawGradient(in rect: CGRect, topAlpha: CGFloat, bottomAlpha: CGFloat, context: CGContext) {
        let colors = [UIColor.black.withAlphaComponent(topAlpha).cgColor,
                      UIColor.black.withAlphaComponent(bottomAlpha).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors,
                                        locations: [0, 1]) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: rect.minY),
                                   end: CGPoint(x: 0, y: rect.maxY),
                                   options: [])
        context.restoreGState()
    }

    private func drawStat(title: String,
                          value: String,
                          at origin: CGPoint,
                          titleSize: CGFloat = 30,
                          valueSize: CGFloat = 78,
                          context: CGContext) {
        draw(text: title, at: origin,
             font: .systemFont(ofSize: titleSize, weight: .semibold),
             color: UIColor.white.withAlphaComponent(0.65))
        draw(text: value, at: CGPoint(x: origin.x, y: origin.y + titleSize + 10),
             font: .monospacedDigitSystemFont(ofSize: valueSize, weight: .bold),
             color: .white)
    }

    private func draw(text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
