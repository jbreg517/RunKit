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

    /// ml/(kg·min) — the unit every VO₂ max figure in Health is expressed in,
    /// regardless of the user's metric/imperial preference.
    static let vo2Unit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    func latestVO2Max() async -> Double? {
        await latestValue(.vo2Max, unit: Self.vo2Unit)
    }

    /// Every VO₂ max reading since `start`, oldest first.
    ///
    /// Apple writes these itself — the Watch estimates cardio fitness during
    /// outdoor walks, runs and hikes — so this is purely a read. Samples are
    /// sparse (at most a few a week, often fewer), which is why the caller asks
    /// for a long window rather than the period the rest of Stats uses.
    ///
    /// An empty result is ambiguous by design: HealthKit does not reveal whether
    /// a *read* was denied, so "no readings" and "no permission" look identical
    /// here. The UI has to phrase its empty state to cover both.
    func vo2MaxSamples(since start: Date) async -> [(date: Date, value: Double)] {
        guard available, let type = HKQuantityType.quantityType(forIdentifier: .vo2Max) else { return [] }
        let range = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: range)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .forward)],
            limit: HKObjectQueryNoLimit)
        do {
            return try await descriptor.result(for: store)
                .map { ($0.endDate, $0.quantity.doubleValue(for: Self.vo2Unit)) }
        } catch {
            return []
        }
    }

    /// Today's step total from Apple Health — the aggregated, cross-device figure the
    /// Health app shows (iPhone + Apple Watch + any source), which `CMPedometer` can't
    /// give because it only sees this iPhone. Nil when Health is unavailable or the
    /// read wasn't authorised, so the caller can fall back to the pedometer.
    func todaySteps() async -> Int? {
        guard available, let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum)
        do {
            guard let sum = try await descriptor.result(for: store)?.sumQuantity() else { return nil }
            return Int(sum.doubleValue(for: .count()))
        } catch {
            return nil
        }
    }

    /// Saves a finished session to Health via the workout builder, attaching the
    /// GPS route when one was recorded so it appears in Apple Fitness alongside the
    /// rest of the suite. Best-effort and on-device only — failures are ignored.
    func save(_ session: ActivitySession) async {
        guard available else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = activityType(for: session.type)
        // `.unknown` only when we genuinely don't know. An indoor session is a
        // positive fact, not an absence of GPS.
        config.locationType = session.isIndoor ? .indoor
                                               : (session.usedGPS ? .outdoor : .unknown)

        let end = session.endedAt ?? Date()
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())

        do {
            try await builder.beginCollection(at: session.startedAt)

            var metadata: [String: Any] = [:]
            // The metadata key, not just the location type, is what makes Apple
            // Health and Fitness display "Indoor Run". Without it a treadmill run is
            // filed as an ordinary one and its pace gets compared against outdoor
            // efforts it has nothing to do with.
            if session.isIndoor { metadata[HKMetadataKeyIndoorWorkout] = true }
            // Health has no notion of external load, so a ruck would otherwise be
            // indistinguishable from an empty-handed walk. A custom key doesn't make
            // Health display it, but it does mean the weight travels with the
            // workout for anything that reads it back — including LiftKit.
            if session.ruckWeightKg > 0 {
                metadata[SuiteCarry.healthMetadataKey] = session.ruckWeightKg
            }
            // `try?`, not `try`: a workout that failed to record its metadata is far
            // better than a run that never saved because of it. Everything after
            // this point is what actually persists the session.
            if !metadata.isEmpty { try? await addMetadata(metadata, to: builder) }

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

    /// `addMetadata` has no async bridge either.
    private func addMetadata(_ metadata: [String: Any], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addMetadata(metadata) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
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

    /// - Parameters:
    ///   - loadKg: external weight carried (a ruck), 0 for an unweighted session.
    ///   - bodyweight: bodyweight in kg at the time, 0 to use the latest known.
    ///
    /// Load scales the estimate by total transported mass — 20 kg on a 70 kg walker
    /// is about 29% more work. That is the basis of the ACSM walking equations,
    /// which are expressed per kilogram of *total* mass. Linear understates a very
    /// heavy pack on a steep climb, but it errs low, and inventing burn that isn't
    /// there would flow straight into FuelKit as real eating headroom.
    ///
    /// Only ever applied to RunKit's own estimate. A watch-recorded session carries
    /// Apple's measured energy instead, and that is never adjusted after the fact.
    static func kcal(type: ActivityType, minutes: Double,
                     loadKg: Double = 0, bodyweight: Double = 0) -> Double {
        let bw = bodyweight > 0 ? bodyweight : bodyweightKg()
        let loadFactor = (loadKg > 0 && bw > 0) ? (bw + loadKg) / bw : 1
        return type.met * bw * (minutes / 60.0) * loadFactor
    }
}
