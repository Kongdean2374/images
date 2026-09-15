import Foundation
import SwiftUI
import MapKit
import UIKit

/// 產生靜態路徑縮圖（分享卡片與 PDF 報表使用）。
enum MapSnapshotter {

    static func snapshot(coordinates: [CLLocationCoordinate2D],
                         speeds: [Double],
                         size: CGSize = CGSize(width: 720, height: 600)) async -> UIImage? {
        guard coordinates.count > 1,
              let region = RouteRenderer.region(for: coordinates, padding: 1.5) else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = 2
        options.mapType = .mutedStandard
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await snapshotter.start()
        } catch {
            return nil
        }

        let segments = RouteRenderer.segments(coordinates: coordinates, speeds: speeds, chunkSize: 4)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            snapshot.image.draw(at: .zero)
            let cg = ctx.cgContext
            cg.setLineWidth(7)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for segment in segments {
                guard segment.coordinates.count > 1 else { continue }
                cg.setStrokeColor(UIColor(segment.color).cgColor)
                cg.beginPath()
                for (index, coord) in segment.coordinates.enumerated() {
                    let point = snapshot.point(for: coord)
                    if index == 0 { cg.move(to: point) } else { cg.addLine(to: point) }
                }
                cg.strokePath()
            }
            if let start = coordinates.first {
                dot(cg, at: snapshot.point(for: start), color: UIColor(Theme.mint))
            }
            if let end = coordinates.last {
                dot(cg, at: snapshot.point(for: end), color: UIColor(Theme.accentWarm))
            }
        }
    }

    private static func dot(_ cg: CGContext, at point: CGPoint, color: UIColor) {
        let r: CGFloat = 9
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillEllipse(in: CGRect(x: point.x - r - 2, y: point.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2))
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
    }
}
