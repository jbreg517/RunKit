import Foundation
import CoreMotion
import Observation

/// On-device step / distance / flights from the motion coprocessor. No network,
/// no location. Triggers the Motion & Fitness permission prompt on first query.
@Observable
final class MotionService {
    static let shared = MotionService()
    private let pedometer = CMPedometer()
    /// Separate instance for one-shot session queries so they don't disturb the
    /// live "today" stream (CMPedometer allows only one active update stream).
    private let sessionPedometer = CMPedometer()

    var steps: Int = 0
    var distanceMeters: Double = 0
    var flights: Int = 0
    var available: Bool = CMPedometer.isStepCountingAvailable()

    /// Begins live updates for today's totals (and backfills today so far).
    func startToday() {
        guard CMPedometer.isStepCountingAvailable() else { available = false; return }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        pedometer.queryPedometerData(from: startOfDay, to: Date()) { [weak self] data, _ in
            guard let data else { return }
            DispatchQueue.main.async { self?.apply(data) }
        }
        pedometer.startUpdates(from: startOfDay) { [weak self] data, _ in
            guard let data else { return }
            DispatchQueue.main.async { self?.apply(data) }
        }
    }

    func stop() { pedometer.stopUpdates() }

    /// One-shot pedometer totals over a window — the GPS-independent fallback for
    /// a finished session's steps and (for walk/run) distance. `nil` if the
    /// coprocessor is unavailable or denied.
    func pedometer(from start: Date, to end: Date) async -> (steps: Int, distance: Double?)? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return await withCheckedContinuation { continuation in
            sessionPedometer.queryPedometerData(from: start, to: end) { data, _ in
                guard let data else { continuation.resume(returning: nil); return }
                continuation.resume(returning: (data.numberOfSteps.intValue,
                                                data.distance?.doubleValue))
            }
        }
    }

    private func apply(_ data: CMPedometerData) {
        steps = data.numberOfSteps.intValue
        distanceMeters = data.distance?.doubleValue ?? distanceMeters
        flights = data.floorsAscended?.intValue ?? flights
    }
}
