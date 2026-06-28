import Foundation
import HealthKit

/// HealthKit bridge — the suite's shared integration point. Reads activity for
/// accuracy/history and writes finished sessions as workouts + active energy so
/// burn flows into Apple Health (and, in turn, FuelKit's calorie targets).
final class HealthService {
    static let shared = HealthService()
    let store = HKHealthStore()
    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        [.stepCount, .distanceWalkingRunning, .flightsClimbed, .activeEnergyBurned]
            .compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            .forEach { s.insert($0) }
        return s
    }

    private var writeTypes: Set<HKSampleType> {
        var s: Set<HKSampleType> = [HKObjectType.workoutType()]
        [.distanceWalkingRunning, .distanceCycling, .activeEnergyBurned]
            .compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            .forEach { s.insert($0) }
        return s
    }

    func requestAuthorization() async {
        guard available else { return }
        try? await store.requestAuthorization(toShare: writeTypes, read: readTypes)
    }

    /// Saves a finished session to Health as an HKWorkout.
    /// TODO: migrate to HKWorkoutBuilder + HKWorkoutRouteBuilder for route data.
    func save(_ session: ActivitySession) async {
        guard available else { return }
        let activity: HKWorkoutActivityType
        switch session.type {
        case .walk: activity = .walking
        case .run:  activity = .running
        case .ride: activity = .cycling
        }
        let end = session.endedAt ?? Date()
        let energy = session.activeEnergyKcal > 0
            ? HKQuantity(unit: .kilocalorie(), doubleValue: session.activeEnergyKcal) : nil
        let distance = session.distanceMeters > 0
            ? HKQuantity(unit: .meter(), doubleValue: session.distanceMeters) : nil

        let workout = HKWorkout(
            activityType: activity,
            start: session.startedAt,
            end: end,
            duration: session.activeSeconds,
            totalEnergyBurned: energy,
            totalDistance: distance,
            metadata: nil
        )
        try? await store.save(workout)
    }
}

/// Rough on-device calorie math. Bodyweight isn't tracked in v1 (assume 70 kg);
/// later this can read bodyweight from HealthKit.
enum HealthCalc {
    static func kcal(type: ActivityType, minutes: Double) -> Double {
        let kg = 70.0
        return type.met * kg * (minutes / 60.0)
    }
}
