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
    /// Treadmill, track, stationary bike. A property of the *session*, not of the
    /// saved workout — the same 5K is run outside one day and on a treadmill the
    /// next, and storing it on the template would be wrong on one of those days.
    ///
    /// Drives `HKMetadataKeyIndoorWorkout`, which is what makes Apple Health label
    /// it "Indoor Run" rather than quietly filing a treadmill run as an outdoor one.
    var isIndoor: Bool = false
    /// Finished but not yet accepted by the user — the review screen is showing, or
    /// was showing when the app died.
    ///
    /// While true the run exists in RunKit's own store but has **not** been written
    /// to Apple Health, published to the suite, or used to tick off a scheduled run.
    /// Those all wait for Save, because a discarded run must leave no trace, and
    /// deleting a workout back out of Health afterwards is not something to rely on.
    ///
    /// Defaults false so every existing session, and every run imported from the
    /// watch (already in Health by the time it arrives), is treated as settled.
    var isPendingReview: Bool = false
    /// The `ScheduledRun` this came from, if any. On the session rather than in view
    /// state so the tick-off survives the app being killed at the review screen —
    /// and so discarding the run leaves the plan untouched.
    var fromScheduleID: UUID?
    /// External weight carried, in **kilograms**, 0 for an unweighted session.
    ///
    /// Stored in kg whatever the user's display units are, so switching to imperial
    /// can't rewrite history. Like `isIndoor` this describes the *session*, not the
    /// workout: the same 5 km route is a ruck on Tuesday and an ordinary walk on
    /// Thursday, and putting the weight on the template would be wrong on Thursday.
    ///
    /// Deliberately a weight rather than a `ruck` flag — the flag is derivable from
    /// the weight, and the weight is what LiftKit needs for load tracking.
    var ruckWeightKg: Double = 0
    /// The user's bodyweight in kg when this session started, or 0 if it wasn't
    /// known. Snapshotted so load-as-a-share-of-bodyweight, and the calorie figure
    /// derived from total transported mass, stay correct after their weight changes.
    var bodyweightKg: Double = 0
    /// True when `activeEnergyKcal` was **measured** rather than estimated — an
    /// Apple Watch recording, where the figure comes from Apple's own model with
    /// live heart rate behind it.
    ///
    /// Editing a session recomputes its calories from METs, which is right for a
    /// phone estimate and destructive for a watch measurement. This is the flag that
    /// tells the two apart. Defaults false, so every phone-recorded session behaves
    /// exactly as it did before.
    var energyMeasured: Bool = false
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
    /// The `ActivitySegment` cards actually run, snapshotted as JSON so history
    /// reflects the session even if the saved workout is later edited or deleted.
    /// Every session has these since v0.45 — a plain run is simply one card. The
    /// attribute keeps its old name so existing stores need no schema change.
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

    /// Aerobic decoupling (v0.43), recomputed alongside the HR summary. Only
    /// meaningful on steady 30-minute-plus GPS runs — `decouplingNote` carries
    /// the reason when it isn't available, which is better than a wrong number.
    var decouplingPercent: Double = 0
    var hasDecoupling: Bool = false
    var decouplingNote: String = ""
    var notes: String?
    /// When the user last corrected the recorded numbers by hand.
    ///
    /// Apple Health is **not** updated by an edit. Rewriting a saved workout means
    /// deleting and re-adding it, which changes its identity and would disturb
    /// anything already referencing it. So RunKit becomes the source of truth for a
    /// corrected run and says so, rather than silently disagreeing with Health.
    var editedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.session)
    var route: [RoutePoint] = []

    init(type: ActivityType, startedAt: Date = Date()) {
        self.typeRaw = type.rawValue
        self.startedAt = startedAt
    }

    var type: ActivityType { ActivityType(rawValue: typeRaw) ?? .walk }
    var workoutType: WorkoutType { WorkoutType(rawValue: workoutTypeRaw) ?? .free }
    var segments: [ActivitySegment] { ActivitySegment.decode(customStepsJSON) }
    var hrZoneSeconds: [Double] { HeartRateZones.decode(hrZoneSecondsJSON) }
    var hasHeartRate: Bool { avgHeartRateBpm > 0 }
    var sortedRoute: [RoutePoint] { route.sorted { $0.timestamp < $1.timestamp } }

    // MARK: Weighted carry

    var isRuck: Bool { ruckWeightKg > 0 }
    /// Kilograms moved over distance — the tonnage analogue, and the figure that
    /// makes two rucks comparable when one was heavier and the other longer.
    var loadKgKilometers: Double { ruckWeightKg * distanceMeters / 1000 }
    /// Time under load, in kg·min. The only volume figure a treadmill ruck has.
    var loadKgMinutes: Double { ruckWeightKg * activeSeconds / 60 }
    /// Load as a share of bodyweight, or nil when bodyweight wasn't known.
    var loadRatio: Double? {
        guard isRuck, bodyweightKg > 0 else { return nil }
        return ruckWeightKg / bodyweightKg
    }
}
