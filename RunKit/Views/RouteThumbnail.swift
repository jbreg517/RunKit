import SwiftUI

/// Small sketch of a route's shape, for list rows.
///
/// Deliberately **not** a `Map`: a MapKit view per row is expensive to
/// instantiate and scroll, and needs tile loading. Drawing the normalised
/// polyline conveys the shape — which is all a thumbnail needs to do — at
/// effectively zero cost.
struct RouteThumbnail: View {
    let points: [RoutePoint]
    var size: CGFloat = 44

    var body: some View {
        Canvas { context, canvasSize in
            guard points.count > 1 else { return }

            let lats = points.map(\.latitude)
            let lons = points.map(\.longitude)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { return }

            // Longitude degrees shrink with latitude; without this correction a
            // north–south route renders as a horizontal smear.
            let midLat = (minLat + maxLat) / 2
            let lonScale = max(0.1, cos(midLat * .pi / 180))
            let spanLat = max(maxLat - minLat, 1e-6)
            let spanLon = max((maxLon - minLon) * lonScale, 1e-6)

            let inset: CGFloat = 3
            let usable = CGSize(width: canvasSize.width - inset * 2,
                                height: canvasSize.height - inset * 2)
            // One scale for both axes preserves the route's real proportions.
            let scale = min(usable.width / spanLon, usable.height / spanLat)
            let drawn = CGSize(width: spanLon * scale, height: spanLat * scale)
            let originX = inset + (usable.width - drawn.width) / 2
            let originY = inset + (usable.height - drawn.height) / 2

            var path = Path()
            for (i, p) in points.enumerated() {
                let x = originX + ((p.longitude - minLon) * lonScale) * scale
                // Flip: latitude grows north, screen y grows down.
                let y = originY + drawn.height - ((p.latitude - minLat) * scale)
                let pt = CGPoint(x: x, y: y)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            context.stroke(path,
                           with: .color(RKColor.accent),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .background(RKColor.surfaceElevated)
        .cornerRadius(RKRadius.small)
    }
}
