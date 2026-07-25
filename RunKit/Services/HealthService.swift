import Foundation
import HealthKit
import CoreLocation

/// HealthKit bridge — the suite's shared integration point. Reads activity for
/// accuracy/history and writes finished sessions as workouts + active energy so
/// burn flows into Apple Health (and, in turn, FuelKit's calorie targets).
final class HealthService {
    static let shared = HealthService()
    let store = HKHealthStore()
    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Latest bodyweight (kg) read from Apple Health, cached so the synchronous
    /// calorie math can use a real weight instead of a fixed assumption. Refreshed
    /// by `refreshBodyweight()`.
    private(set) var latestBodyweightKg: Double?

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        // bodyMass: shared across the suite (LiftKit / FuelKit log it) so runs get
        // an accurate calorie burn.
        // heartRate and friends are READ-ONLY and need no Watch app of our own:
        // HealthKit surfaces samples written by any source (Apple Watch, a chest
        // strap, another app), and Apple Watch computes vo2Max / restingHeartRate
        // / HRV / recovery for free. See docs/ANALYTICS.md §1.
        [.stepCount, .distanceWalkingRunning, .flightsClimbed, .activeEnergyBurned, .bodyMass,
         .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max,
         .heartRateRecoveryOneMinute]
            .compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            .forEach { s.insert($0) }
        return s
    }

    private var writeTypes: Set<HKSampleType> {
        var s: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        [.distanceWalkingRunning, .distanceCycling, .activeEnergyBurned]
            .compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            .forEach { s.insert($0) }
        return s
    }

    func requestAuthorization() async {
        guard available else { return }
        try? await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        await refreshBodyweight()
    }

    /// Refreshes the cached bodyweight from Apple Health, falling back to the
    /// suite-shared profile (an app may write it there without Health access).
    /// Call at launch and before a session so calorie math uses a real weight.
    func refreshBodyweight() async {
        if let kg = await latestBodyMassKg() {
            latestBodyweightKg = kg
        } else if let lb = SuiteProfileStore.load()?.latestWeightLb, lb > 0 {
            latestBodyweightKg = lb * 0.453592
        }
    }

    /// Most-recent bodyweight in kilograms from Apple Health, or nil.
    private func latestBodyMassKg() async -> Double? {
        guard available, let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: nil)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1)
        do {
            let samples = try await descriptor.result(for: store)
            return samples.first?.quantity.doubleValue(for: .gramUnit(with: .kilo))
        } catch {
            return nil
        }
    }

    // MARK: Heart rate (read-only)

    /// Heart-rate samples in a window, oldest first, as (time, bpm). Empty when
    /// nothing was recording — which is the normal case without a Watch.
    func heartRateSamples(from start: Date, to end: Date) async -> [(date: Date, bpm: Double)] {
        guard available, end > start,
              let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let range = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: range)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: HKObjectQueryNoLimit)
        do {
            let unit = HKUnit.count().unitDivided(by: .minute())
            return try await descriptor.result(for: store)
                .map { ($0.startDate, $0.quantity.doubleValue(for: unit)) }
        } catch {
            return []
        }
    }

    /// Most recent value of a simple quantity type — resting HR, VO₂ max, HRV.
    func latestValue(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard available, let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: nil)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1)
        return try? await descriptor.result(for: store).first?.quantity.doubleValue(for: unit)
    }

    func latestRestingHeartRate() async -> Double? {
        await latestValue(.restingHeartRate, unit: .count().unitDivided(by: .minute()))
    }

    func latestVO2Max() async -> Double? {
        // ml/(kg·min)
        let unit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        return await latestValue(.vo2Max, unit: unit)
    }

    /// Saves a finished session to Health via the workout builder, attaching the
    /// GPS route when one was recorded so it appears in Apple Fitness alongside the
    /// rest of the suite. Best-effort and on-device only — failures are ignored.
    func save(_ session: ActivitySession) async {
        guard available else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = activityType(for: session.type)
        config.locationType = session.usedGPS ? .outdoor : .unknown

        let end = session.endedAt ?? Date()
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())

        do {
            try await builder.beginCollection(at: session.startedAt)

            var samples: [HKSample] = []
            if session.activeEnergyKcal > 0,
               let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                samples.append(HKQuantitySample(
                    type: energyType,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: session.activeEnergyKcal),
                    start: session.startedAt, end: end))
            }
            if session.distanceMeters > 0 {
                let id: HKQuantityTypeIdentifier = session.type == .ride
                    ? .distanceCycling : .distanceWalkingRunning
                if let distType = HKQuantityType.quantityType(forIdentifier: id) {
                    samples.append(HKQuantitySample(
                        type: distType,
                        quantity: HKQuantity(unit: .meter(), doubleValue: session.distanceMeters),
                        start: session.startedAt, end: end))
                }
            }
            if !samples.isEmpty { try await add(samples, to: builder) }

            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { return }

            await attachRoute(from: session, to: workout)
        } catch {
            // On-device only; nothing user-facing in v1.
        }
    }

    /// `HKWorkoutBuilder.add(_:)` has no async bridge in this SDK, so wrap the
    /// completion-handler form.
    private func add(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.add(samples) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// Attaches the recorded GPS path to a saved workout as an HKWorkoutRoute.
    private func attachRoute(from session: ActivitySession, to workout: HKWorkout) async {
        let points = session.sortedRoute
        guard points.count >= 2 else { return }

        let locations = points.map { p in
            CLLocation(
                coordinate: p.coordinate,
                altitude: p.altitude,
                horizontalAccuracy: p.horizontalAccuracy >= 0 ? p.horizontalAccuracy : 5,
                verticalAccuracy: -1,
                course: -1,
                speed: max(0, p.speed),
                timestamp: p.timestamp)
        }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        do {
            try await routeBuilder.insertRouteData(locations)
            try await routeBuilder.finishRoute(with: workout, metadata: nil)
        } catch {
            // The route is a nice-to-have; the workout itself already saved.
        }
    }

    private func activityType(for type: ActivityType) -> HKWorkoutActivityType {
        switch type {
        case .walk: return .walking
        case .run:  return .running
        case .ride: return .cycling
        }
    }
}

/// Rough on-device calorie math. Bodyweight comes from Apple Health (shared by
/// the suite) when available, then the shared profile, then a 70 kg fallback.
enum HealthCalc {
    /// Best available bodyweight in kg for calorie estimates.
    static func bodyweightKg() -> Double {
        if let kg = HealthService.shared.latestBodyweightKg, kg > 0 { return kg }
        if let lb = SuiteProfileStore.load()?.latestWeightLb, lb > 0 { return lb * 0.453592 }
        return 70.0
    }

    static func kcal(type: ActivityType, minutes: Double) -> Double {
        type.met * bodyweightKg() * (minutes / 60.0)
    }
}
