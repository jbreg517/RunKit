import Foundation
import SwiftData

@Model
final class ActivitySession {
    var id: UUID = UUID()
    var typeRaw: String = ActivityType.walk.rawValue
    var startedAt: Date = Date()
    var endedAt: Date?
    /// Active seconds — excludes any time spent paused.
    var activeSeconds: TimeInterval = 0
    /// Total wall-clock seconds spent paused (v0.27). `activeSeconds +
    /// pausedSeconds` is the elapsed wall time from start to finish.
    var pausedSeconds: TimeInterval = 0
    var distanceMeters: Double = 0
    var steps: Int = 0
    var flights: Int = 0
    var activeEnergyKcal: Double = 0
    var usedGPS: Bool = false
    var manualDistance: Bool = false
    /// True when some of `distanceMeters` came from a fallback (pedometer fill or
    /// a straight-line GPS-gap bridge) rather than a clean GPS track.
    var distanceEstimated: Bool = false
    /// Optional session goal: `"distance"` (meters) or `"time"` (seconds); nil = none.
    var goalKind: String?
    var goalTarget: Double = 0
    /// Run type + structured params (added v0.15). Distance/Time reuse `goalTarget`.
    var workoutTypeRaw: String = WorkoutType.free.rawValue
    var intervalWork: Double = 0          // seconds
    var intervalRest: Double = 0          // seconds
    var intervalReps: Int = 0
    var paceTargetSecPerMeter: Double = 0 // unit-agnostic target pace
    /// Custom multi-segment workout (v0.29): the steps actually run, snapshotted
    /// as JSON so history reflects the session even if the saved workout is
    /// later edited or deleted.
    var customStepsJSON: String = "[]"
    var customWorkoutName: String = ""

    /// Heart-rate summary (v0.41), read from HealthKit at save time and cached
    /// here so Stats never re-queries per render. 0 = none was recorded, which
    /// is normal without an Apple Watch. `hrCheckedAt` distinguishes "no watch"
    /// from "not looked yet", so backfill can skip sessions already examined.
    var avgHeartRateBpm: Double = 0
    var maxHeartRateBpm: Double = 0
    var hrZoneSecondsJSON: String = "[]"
    var hrCheckedAt: Date?
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.session)
    var route: [RoutePoint] = []

    init(type: ActivityType, startedAt: Date = Date()) {
        self.typeRaw = type.rawValue
        self.startedAt = startedAt
    }

    var type: ActivityType { ActivityType(rawValue: typeRaw) ?? .walk }
    var workoutType: WorkoutType { WorkoutType(rawValue: workoutTypeRaw) ?? .free }
    var customSteps: [WorkoutStep] { WorkoutStep.decode(customStepsJSON) }
    var hrZoneSeconds: [Double] { HeartRateZones.decode(hrZoneSecondsJSON) }
    var hasHeartRate: Bool { avgHeartRateBpm > 0 }
    var sortedRoute: [RoutePoint] { route.sorted { $0.timestamp < $1.timestamp } }
}
