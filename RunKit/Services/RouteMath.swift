import Foundation
import CoreLocation
import MapKit

/// A contiguous run of route coordinates sharing the same source. `estimated`
/// runs bridged a GPS outage and are drawn faded/dashed on the map.
struct RouteSegment: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let estimated: Bool
}

/// One distance split (per km or per mile). `partial` marks a trailing fragment.
struct Split: Identifiable {
    let id = UUID()
    let index: Int
    let meters: Double
    let seconds: Double
    let partial: Bool
}

/// Pure geometry/stats over a recorded route. No I/O, no state — easy to reason
/// about and (later) unit-test once a test target exists.
enum RouteMath {

    // MARK: Segmenting (GPS vs estimated)

    /// Splits the path into runs of same-source coordinates so the map can draw
    /// GPS stretches solid and estimated (gap-bridged) stretches dashed. Each new
    /// run starts at the previous point so the polyline stays connected.
    /// Convention: the segment ending at point `i` is estimated iff `points[i].isEstimated`.
    static func segments(_ points: [RoutePoint]) -> [RouteSegment] {
        guard points.count >= 2 else {
            return points.first.map { [RouteSegment(coordinates: [$0.coordinate], estimated: false)] } ?? []
        }
        var result: [RouteSegment] = []
        var current = [points[0].coordinate]
        var currentEstimated = points[1].isEstimated
        for i in 1..<points.count {
            let segEstimated = points[i].isEstimated
            if segEstimated == currentEstimated {
                current.append(points[i].coordinate)
            } else {
                result.append(RouteSegment(coordinates: current, estimated: currentEstimated))
                current = [points[i - 1].coordinate, points[i].coordinate]
                currentEstimated = segEstimated
            }
        }
        result.append(RouteSegment(coordinates: current, estimated: currentEstimated))
        return result
    }

    // MARK: Display helpers

    /// Thins a long route for smooth rendering while preserving estimated/GPS
    /// boundaries and the endpoints. Storage keeps every point; only the polyline
    /// is decimated.
    static func downsample(_ points: [RoutePoint], target: Int = 500) -> [RoutePoint] {
        guard points.count > target, target > 1 else { return points }
        let step = Double(points.count) / Double(target)
        var result: [RoutePoint] = []
        var threshold = 0.0
        var lastEstimated: Bool?
        for (i, p) in points.enumerated() {
            let boundary = (p.isEstimated != lastEstimated) && lastEstimated != nil
            if Double(i) >= threshold || boundary || i == points.count - 1 {
                result.append(p)
                threshold += step
            }
            lastEstimated = p.isEstimated
        }
        return result
    }

    /// Bounding region for the route, padded so the line isn't flush to the edges.
    static func region(_ points: [RoutePoint]) -> MKCoordinateRegion? {
        guard let first = points.first?.coordinate else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points {
            let c = p.coordinate
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.002),
                                    longitudeDelta: max((maxLon - minLon) * 1.3, 0.002))
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: Stats

    /// Per-unit splits (1 km metric / 1 mi imperial), interpolating the crossing
    /// time within the segment that straddles each boundary.
    static func splits(_ points: [RoutePoint], unit: UnitSystem) -> [Split] {
        guard points.count >= 2 else { return [] }
        let unitMeters = unit == .metric ? 1000.0 : 1609.344
        var splits: [Split] = []
        var sinceBoundary = 0.0
        var boundaryTime = points[0].timestamp
        var index = 1
        for i in 1..<points.count {
            let segMeters = distance(points[i - 1], points[i])
            let segSeconds = points[i].timestamp.timeIntervalSince(points[i - 1].timestamp)
            sinceBoundary += segMeters
            while sinceBoundary >= unitMeters {
                let overshoot = sinceBoundary - unitMeters
                let frac = segMeters > 0 ? 1 - (overshoot / segMeters) : 1
                let crossing = points[i - 1].timestamp.addingTimeInterval(segSeconds * frac)
                splits.append(Split(index: index, meters: unitMeters,
                                    seconds: crossing.timeIntervalSince(boundaryTime), partial: false))
                index += 1
                boundaryTime = crossing
                sinceBoundary = overshoot
            }
        }
        if sinceBoundary > 1 {
            splits.append(Split(index: index, meters: sinceBoundary,
                                seconds: points.last!.timestamp.timeIntervalSince(boundaryTime),
                                partial: true))
        }
        return splits
    }

    /// Total ascent: sum of positive altitude deltas above a 1 m noise threshold.
    static func elevationGain(_ points: [RoutePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var gain = 0.0
        for i in 1..<points.count {
            let delta = points[i].altitude - points[i - 1].altitude
            if delta > 1 { gain += delta }
        }
        return gain
    }

    /// Max reported speed (m/s), discarding implausible outliers per activity type.
    static func maxSpeed(_ points: [RoutePoint], type: ActivityType) -> Double {
        let cap: Double
        switch type {
        case .walk: cap = 4.5
        case .run:  cap = 8.0
        case .ride: cap = 27.0
        }
        return points.map(\.speed).filter { $0 >= 0 && $0 <= cap }.max() ?? 0
    }

    // MARK: Private

    private static func distance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
