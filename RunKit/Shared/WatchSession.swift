import Foundation

/// A run recorded on the wrist, on its way back to the phone.
///
/// Sent as a **file** rather than a message: an hour's route at 1 Hz is a few
/// hundred kilobytes, well past what `sendMessage` will carry, and the transfer has
/// to survive the phone being out of range for the whole run. `transferFile` queues
/// to disk and retries on its own.
///
/// The watch has already written this run to HealthKit itself, so this payload is
/// only for RunKit's own history — the phone must never re-save it to Health or the
/// workout appears twice and the energy is double-counted.
struct WatchSessionPayload: Codable, Hashable {

    struct Point: Codable, Hashable {
        var t: Date = Date()
        var lat: Double = 0
        var lon: Double = 0
        var alt: Double = 0
        var acc: Double = 0
        var spd: Double = 0

        init(t: Date, lat: Double, lon: Double, alt: Double, acc: Double, spd: Double) {
            self.t = t; self.lat = lat; self.lon = lon
            self.alt = alt; self.acc = acc; self.spd = spd
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            t = try c.decodeIfPresent(Date.self, forKey: .t) ?? Date()
            lat = try c.decodeIfPresent(Double.self, forKey: .lat) ?? 0
            lon = try c.decodeIfPresent(Double.self, forKey: .lon) ?? 0
            alt = try c.decodeIfPresent(Double.self, forKey: .alt) ?? 0
            acc = try c.decodeIfPresent(Double.self, forKey: .acc) ?? 0
            spd = try c.decodeIfPresent(Double.self, forKey: .spd) ?? 0
        }
    }

    /// Generated on the watch and **stable across retries** — this is what makes the
    /// transfer idempotent. WatchConnectivity can deliver a queued file more than
    /// once, and without a key the phone would happily insert the same run twice.
    var id: UUID = UUID()
    var activityRaw: String = ActivityType.run.rawValue
    var startedAt: Date = Date()
    var endedAt: Date = Date()
    var activeSeconds: Double = 0
    var pausedSeconds: Double = 0
    var distanceMeters: Double = 0
    var activeEnergyKcal: Double = 0
    var usedGPS: Bool = false
    /// Treadmill, track or stationary bike — drives HKMetadataKeyIndoorWorkout and
    /// keeps the phone from filing a treadmill run alongside outdoor efforts.
    var isIndoor: Bool = false
    /// External weight carried, in kilograms — a ruck. 0 for an unweighted session.
    ///
    /// The watch's `activeEnergyKcal` is **not** adjusted for it: that figure is
    /// Apple's own measurement with live heart rate behind it, and a pack shows up
    /// there as a higher heart rate already. Only RunKit's own phone-side estimate
    /// scales with load.
    var ruckWeightKg: Double = 0
    /// Steps over the workout. Carried so `StatsCalculator.averageCadence` works for
    /// wrist-recorded runs — it reads `ActivitySession.steps`, and without this a
    /// watch run would silently drop out of the cadence average.
    var steps: Int = 0
    var avgHeartRateBpm: Double = 0
    var maxHeartRateBpm: Double = 0
    /// Seconds in each of the five zones, computed on the watch from live samples —
    /// far better than the phone's after-the-fact HealthKit re-query, which only
    /// sees whatever got written.
    var hrZoneSeconds: [Double] = Array(repeating: 0, count: 5)
    /// The cards actually run, snapshotted.
    var segments: [ActivitySegment] = []
    var workoutName: String = ""
    /// Set when this came off a scheduled run, so the phone can tick it off.
    var scheduleID: UUID?
    var route: [Point] = []

    var activity: ActivityType { ActivityType(rawValue: activityRaw) ?? .run }

    init() {}

    /// Optional on the wire throughout, for the usual reason: the watch app and the
    /// phone app update independently, and a run that fails to decode is a run the
    /// user actually did and can never get back.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        activityRaw = try c.decodeIfPresent(String.self, forKey: .activityRaw) ?? ActivityType.run.rawValue
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt) ?? Date()
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 0
        pausedSeconds = try c.decodeIfPresent(Double.self, forKey: .pausedSeconds) ?? 0
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
        activeEnergyKcal = try c.decodeIfPresent(Double.self, forKey: .activeEnergyKcal) ?? 0
        usedGPS = try c.decodeIfPresent(Bool.self, forKey: .usedGPS) ?? false
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0
        isIndoor = try c.decodeIfPresent(Bool.self, forKey: .isIndoor) ?? false
        ruckWeightKg = try c.decodeIfPresent(Double.self, forKey: .ruckWeightKg) ?? 0
        avgHeartRateBpm = try c.decodeIfPresent(Double.self, forKey: .avgHeartRateBpm) ?? 0
        maxHeartRateBpm = try c.decodeIfPresent(Double.self, forKey: .maxHeartRateBpm) ?? 0
        let zones = try c.decodeIfPresent([Double].self, forKey: .hrZoneSeconds) ?? []
        hrZoneSeconds = zones.count == 5 ? zones : Array(repeating: 0, count: 5)
        segments = try c.decodeIfPresent([ActivitySegment].self, forKey: .segments) ?? []
        workoutName = try c.decodeIfPresent(String.self, forKey: .workoutName) ?? ""
        scheduleID = try c.decodeIfPresent(UUID.self, forKey: .scheduleID)
        route = try c.decodeIfPresent([Point].self, forKey: .route) ?? []
    }
}
