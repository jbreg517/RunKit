import Foundation
import CoreLocation
import Observation

/// Opt-in GPS for active sessions. Uses When-In-Use authorization plus the
/// location background mode so recording continues with the screen off while a
/// session is running. Accumulates distance from accepted fixes. Routes/points
/// are kept on-device only.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()

    var authorization: CLAuthorizationStatus = .notDetermined
    var isTracking = false
    private(set) var distanceMeters: Double = 0
    private(set) var lastLocation: CLLocation?
    /// True if the track had at least one GPS outage (gap between accepted fixes),
    /// so the session knows its distance is partly estimated.
    private(set) var hadGap = false
    private var lastFixTime: Date?

    /// A fix arriving more than this long after the previous accepted one is
    /// treated as bridging a GPS outage; the connecting segment is estimated.
    private let gapThreshold: TimeInterval = 8

    /// Called for each accepted fix with whether its incoming segment was
    /// estimated (bridged a gap), so a session can persist route points.
    var onPoint: ((CLLocation, Bool) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 5
        authorization = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startTracking() {
        distanceMeters = 0
        lastLocation = nil
        lastFixTime = nil
        hadGap = false
        isTracking = true
        // Safe to enable only because UIBackgroundModes includes `location`.
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    func stopTracking() {
        isTracking = false
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isTracking else { return }
        for loc in locations {
            // Drop noisy / invalid fixes.
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { continue }
            var estimated = false
            if let last = lastLocation {
                let step = loc.distance(from: last)
                guard step > 1 else { continue }   // ignore sub-meter jitter
                // A long pause between accepted fixes means GPS dropped out; the
                // straight line bridging the gap is an estimate, not a measured path.
                if let t = lastFixTime, loc.timestamp.timeIntervalSince(t) > gapThreshold {
                    estimated = true
                    hadGap = true
                }
                distanceMeters += step
            }
            lastLocation = loc
            lastFixTime = loc.timestamp
            onPoint?(loc, estimated)
        }
    }
}
