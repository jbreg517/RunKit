import Foundation

/// Everything about an in-progress run that HealthKit does *not* hold.
///
/// `HKWorkoutSession` survives the app being killed — `recoverActiveWorkoutSession`
/// hands it back, still running, with its distance, heart rate and energy intact.
/// What dies with the process is everything RunKit layered on top: which card
/// you're on, how far into the interval block, the zone buckets, the splits. Without
/// this, recovery would resume a structured workout as a shapeless one.
///
/// Written to `UserDefaults` rather than a file: it's a few hundred bytes, rewritten
/// every 30 seconds, and the atomic-write behaviour is exactly what's wanted when
/// the process can be killed at any moment.
struct WatchRunState: Codable {
    var item = WatchMenu.Item()
    var startedAt = Date()
    var pausedTotal: TimeInterval = 0
    var pausedAt: Date?
    var autoPaused = false

    var segIndex = 0
    var segStartElapsed: TimeInterval = 0
    var segStartMeters: Double = 0
    var segmentsDone = false
    var intRep = 1
    var intPhaseIsWork = true
    var phaseEndsAt: TimeInterval = 0
    var intervalsDone = false

    var markedUnits = 0
    var lastSplitElapsed: TimeInterval = 0
    var splits: [TimeInterval] = []
    var zoneSeconds: [Double] = Array(repeating: 0, count: 5)
    var bpmSum: Double = 0
    var bpmSamples = 0
    var maxBpm: Double = 0
    var elevationGain: Double = 0
    var usedGPS = false
    var isIndoor = false

    // MARK: Persistence

    private static let key = "watchRunState.v1"

    static func save(_ state: WatchRunState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> WatchRunState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WatchRunState.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Optional throughout, same rule as the wire formats: this is read by a build
    /// that may be newer than the one that wrote it, and a throwing decode would
    /// turn a recoverable run into a lost one.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decodeIfPresent(WatchMenu.Item.self, forKey: .item) ?? WatchMenu.Item()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        pausedTotal = try c.decodeIfPresent(TimeInterval.self, forKey: .pausedTotal) ?? 0
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        autoPaused = try c.decodeIfPresent(Bool.self, forKey: .autoPaused) ?? false
        segIndex = try c.decodeIfPresent(Int.self, forKey: .segIndex) ?? 0
        segStartElapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .segStartElapsed) ?? 0
        segStartMeters = try c.decodeIfPresent(Double.self, forKey: .segStartMeters) ?? 0
        segmentsDone = try c.decodeIfPresent(Bool.self, forKey: .segmentsDone) ?? false
        intRep = try c.decodeIfPresent(Int.self, forKey: .intRep) ?? 1
        intPhaseIsWork = try c.decodeIfPresent(Bool.self, forKey: .intPhaseIsWork) ?? true
        phaseEndsAt = try c.decodeIfPresent(TimeInterval.self, forKey: .phaseEndsAt) ?? 0
        intervalsDone = try c.decodeIfPresent(Bool.self, forKey: .intervalsDone) ?? false
        markedUnits = try c.decodeIfPresent(Int.self, forKey: .markedUnits) ?? 0
        lastSplitElapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .lastSplitElapsed) ?? 0
        splits = try c.decodeIfPresent([TimeInterval].self, forKey: .splits) ?? []
        let zones = try c.decodeIfPresent([Double].self, forKey: .zoneSeconds) ?? []
        zoneSeconds = zones.count == 5 ? zones : Array(repeating: 0, count: 5)
        bpmSum = try c.decodeIfPresent(Double.self, forKey: .bpmSum) ?? 0
        bpmSamples = try c.decodeIfPresent(Int.self, forKey: .bpmSamples) ?? 0
        maxBpm = try c.decodeIfPresent(Double.self, forKey: .maxBpm) ?? 0
        elevationGain = try c.decodeIfPresent(Double.self, forKey: .elevationGain) ?? 0
        usedGPS = try c.decodeIfPresent(Bool.self, forKey: .usedGPS) ?? false
        isIndoor = try c.decodeIfPresent(Bool.self, forKey: .isIndoor) ?? false
    }
}
