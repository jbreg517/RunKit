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

    /// Called for each accepted fix, so a session can persist route points.
    var onPoint: ((CLLocation) -> Void)?

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
            if let last = lastLocation {
                let step = loc.distance(from: last)
                guard step > 1 else { continue }   // ignore sub-meter jitter
                distanceMeters += step
            }
            lastLocation = loc
            onPoint?(loc)
        }
    }
}
