import Foundation

/// One card in the activity builder: an activity, an optional goal, and whatever
/// decides when the card is over.
///
/// **Pure Foundation on purpose.** This file is a member of the watch target too,
/// so the wrist runs the exact same card semantics as the phone rather than a
/// parallel model that could drift. `CustomWorkout` — the SwiftData `@Model` that
/// stores these — lives in its own file for that reason.
///
/// Every session is now a list of these. A plain run is one segment with no goal;
/// a structured workout is several — "10 min warm-up walk", "5 mi @ 8:00",
/// "1 mi cool-down". There is no separate "custom workout" concept any more: the
/// simple case is just the one-card case.
struct ActivitySegment: Codable, Hashable, Identifiable {

    /// What you're aiming at inside this card.
    ///
    /// `distance` and `time` are self-terminating — the goal *is* the end.
    /// `pace` and `heartRate` are targets you *hold*, so on their own they'd never
    /// finish; they carry a separate length (`basis` + amount) saying how far to
    /// hold them. `none` is open-ended: it runs until you tap Next, or until you
    /// finish if it's the last card.
    enum Goal: String, Codable, CaseIterable, Identifiable {
        case none, distance, time, pace, heartRate, intervals

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none:      return "None"
            case .distance:  return "Distance"
            case .time:      return "Time"
            case .pace:      return "Pace"
            case .heartRate: return "Heart Rate"
            case .intervals: return "Intervals"
            }
        }

        var sfSymbol: String {
            switch self {
            case .none:      return "infinity"
            case .distance:  return "ruler"
            case .time:      return "timer"
            case .pace:      return "speedometer"
            case .heartRate: return "heart.fill"
            case .intervals: return "repeat"
            }
        }

        /// Targets you hold rather than reach, so they need a "for how long".
        var needsLength: Bool { self == .pace || self == .heartRate }
    }

    /// How a card ends when its goal doesn't decide by itself.
    enum Basis: String, Codable, CaseIterable, Identifiable {
        case time, distance
        var id: String { rawValue }
        var label: String { self == .time ? "Time" : "Distance" }
    }

    var id: UUID = UUID()
    var activity: ActivityType = .run
    var goal: Goal = .none
    /// Optional name for the card — "Warm-up", "Cool-down". Cosmetic only, but it
    /// is what the voice coach announces when set.
    var label: String = ""
    var basis: Basis = .time
    /// Used when the card ends on time.
    var seconds: Double = 600
    /// Used when the card ends on distance.
    var meters: Double = 1609.344
    /// Stored seconds-per-metre so switching units never moves the target.
    var paceTargetSecPerMeter: Double = 0
    /// 1...5, matching `HeartRateZones`.
    var hrZone: Int = 2
    var work: Int = 30      // seconds
    var rest: Int = 90      // seconds
    var reps: Int = 8

    // MARK: Termination

    /// What ends this card — or nil when nothing does and only Next (or Finish)
    /// moves it along. Intervals end on their own rep count, not a basis.
    var endBasis: Basis? {
        switch goal {
        case .none, .intervals:  return nil
        case .distance:          return .distance
        case .time:              return .time
        case .pace, .heartRate:  return basis
        }
    }

    var endsOnDistance: Bool { endBasis == .distance }

    /// Seconds this card runs for, when it ends on time.
    var endSeconds: Double { seconds }
    /// Metres this card runs for, when it ends on distance.
    var endMeters: Double { meters }

    /// Elapsed seconds a full interval block takes: every rep works, and every rep
    /// but the last is followed by a rest.
    var intervalSeconds: Double {
        Double(max(1, reps) * max(1, work) + max(0, reps - 1) * max(0, rest))
    }

    var hasPaceTarget: Bool { goal == .pace && paceTargetSecPerMeter > 0 }
    var hasHeartRateTarget: Bool { goal == .heartRate }

    // MARK: Display

    /// "10 min" / "5.00 mi", in the user's units. Keyed off `endBasis` rather than
    /// `basis`, because a distance goal ends on distance whatever `basis` happens
    /// to hold — that field only means something for a held target.
    func amountText(_ unit: UnitSystem) -> String {
        if endBasis == .distance {
            let d = unit.distance(meters)
            let n = d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
            return "\(n) \(unit.distanceUnit)"
        }
        let m = Int((seconds / 60).rounded())
        return m > 0 ? "\(m) min" : "\(Int(seconds)) sec"
    }

    /// "8:00 /mi" — or on a ride, the same target read as a speed.
    func paceText(_ unit: UnitSystem) -> String {
        guard paceTargetSecPerMeter > 0 else { return "" }
        let perUnit = paceTargetSecPerMeter * unit.metersPerUnit
        if activity == .ride {
            return unit.speedString(metersPerSecond: 1 / paceTargetSecPerMeter)
        }
        return unit.paceString(secondsPerUnit: perUnit)
    }

    /// The one-line description under the card title.
    func summary(_ unit: UnitSystem) -> String {
        switch goal {
        case .none:
            return "Open — until you tap Next"
        case .distance, .time:
            return amountText(unit)
        case .pace:
            let p = paceText(unit)
            return p.isEmpty ? "Pace · \(amountText(unit))" : "\(p) for \(amountText(unit))"
        case .heartRate:
            return "Zone \(hrZone) for \(amountText(unit))"
        case .intervals:
            return "\(reps) × \(work)s / \(rest)s"
        }
    }

    // MARK: Codable

    /// Hand-written so older saved workouts still load. Before v0.45 a segment was
    /// a `WorkoutStep` — `kind` + `basis` + an optional pace — with no goal at all,
    /// so the goal is inferred and `kind` becomes the card's label.
    enum CodingKeys: String, CodingKey {
        case id, activity, goal, label, basis, seconds, meters
        case paceTargetSecPerMeter, hrZone, work, rest, reps
        case kind   // legacy
    }

    init(activity: ActivityType = .run,
         goal: Goal = .none,
         label: String = "",
         basis: Basis = .time,
         seconds: Double = 600,
         meters: Double = 1609.344,
         paceTargetSecPerMeter: Double = 0,
         hrZone: Int = 2,
         work: Int = 30,
         rest: Int = 90,
         reps: Int = 8) {
        self.activity = activity
        self.goal = goal
        self.label = label
        self.basis = basis
        self.seconds = seconds
        self.meters = meters
        self.paceTargetSecPerMeter = paceTargetSecPerMeter
        self.hrZone = hrZone
        self.work = work
        self.rest = rest
        self.reps = reps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        activity = try c.decodeIfPresent(ActivityType.self, forKey: .activity) ?? .run
        basis = try c.decodeIfPresent(Basis.self, forKey: .basis) ?? .time
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 600
        meters = try c.decodeIfPresent(Double.self, forKey: .meters) ?? 1609.344
        paceTargetSecPerMeter = try c.decodeIfPresent(Double.self, forKey: .paceTargetSecPerMeter) ?? 0
        hrZone = try c.decodeIfPresent(Int.self, forKey: .hrZone) ?? 2
        work = try c.decodeIfPresent(Int.self, forKey: .work) ?? 30
        rest = try c.decodeIfPresent(Int.self, forKey: .rest) ?? 90
        reps = try c.decodeIfPresent(Int.self, forKey: .reps) ?? 8

        let legacyKind = try c.decodeIfPresent(String.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label)
            ?? Self.legacyLabel(legacyKind)

        if let goal = try c.decodeIfPresent(Goal.self, forKey: .goal) {
            self.goal = goal
        } else {
            // Pre-v0.45: a step always ended on its basis, and a pace target was
            // just an extra field rather than a goal of its own.
            self.goal = paceTargetSecPerMeter > 0 ? .pace : (basis == .time ? .time : .distance)
        }
    }

    /// Written by hand because `CodingKeys` carries a `kind` case with no property
    /// behind it — it exists only so `init(from:)` can read pre-v0.45 workouts.
    /// Leaving encoding to synthesis with a dangling key is not something to bet a
    /// build on.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(activity, forKey: .activity)
        try c.encode(goal, forKey: .goal)
        try c.encode(label, forKey: .label)
        try c.encode(basis, forKey: .basis)
        try c.encode(seconds, forKey: .seconds)
        try c.encode(meters, forKey: .meters)
        try c.encode(paceTargetSecPerMeter, forKey: .paceTargetSecPerMeter)
        try c.encode(hrZone, forKey: .hrZone)
        try c.encode(work, forKey: .work)
        try c.encode(rest, forKey: .rest)
        try c.encode(reps, forKey: .reps)
    }

    private static func legacyLabel(_ kind: String?) -> String {
        switch kind {
        case "warmup":   return "Warm-up"
        case "recovery": return "Recovery"
        case "cooldown": return "Cool-down"
        default:         return ""
        }
    }
}

// MARK: - Encoding

extension ActivitySegment {
    static func encode(_ segments: [ActivitySegment]) -> String {
        guard let data = try? JSONEncoder().encode(segments),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decode(_ json: String) -> [ActivitySegment] {
        guard let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([ActivitySegment].self, from: data)
        else { return [] }
        return segments
    }

    /// What a brand-new session opens with: one open run. The one-card case is the
    /// common case, so the builder should already be sitting on it.
    static var starter: [ActivitySegment] {
        [ActivitySegment(activity: .run, goal: .none)]
    }

    /// The card that a `+` adds — a mile of work, since that's the usual next move
    /// after a warm-up.
    static var added: ActivitySegment {
        ActivitySegment(activity: .run, goal: .distance, basis: .distance, meters: 1609.344)
    }
}

// MARK: - Bridging from the flat, pre-card representation

extension ActivitySegment {
    /// Builds cards from the older flat parameters still carried by `WorkoutRecipe`
    /// and by scheduled runs saved before v0.45.
    static func fromLegacy(type: WorkoutType, activity: ActivityType,
                           meters: Double, minutes: Int,
                           work: Int, rest: Int, reps: Int,
                           paceSecPerMeter: Double) -> [ActivitySegment] {
        switch type {
        case .free:
            return [ActivitySegment(activity: activity, goal: .none)]
        case .distance:
            return [ActivitySegment(activity: activity, goal: .distance,
                                    basis: .distance, meters: meters)]
        case .time:
            return [ActivitySegment(activity: activity, goal: .time,
                                    basis: .time, seconds: Double(minutes) * 60)]
        case .intervals:
            return [ActivitySegment(activity: activity, goal: .intervals,
                                    work: work, rest: rest, reps: reps)]
        case .pace:
            return [ActivitySegment(activity: activity, goal: .pace, basis: .time,
                                    seconds: Double(max(minutes, 30)) * 60,
                                    paceTargetSecPerMeter: paceSecPerMeter)]
        case .heartRate:
            return [ActivitySegment(activity: activity, goal: .heartRate, basis: .time,
                                    seconds: Double(max(minutes, 30)) * 60)]
        case .custom:
            return []
        }
    }

    static func from(recipe: WorkoutRecipe, activity: ActivityType = .run) -> [ActivitySegment] {
        fromLegacy(type: recipe.workoutType, activity: activity,
                   meters: recipe.meters, minutes: recipe.minutes,
                   work: recipe.work, rest: recipe.rest, reps: recipe.reps,
                   paceSecPerMeter: 0)
    }

    /// Collapses a card list back to the single `WorkoutType` that history, Stats
    /// and `AerobicAnalysis` classify a session by. Anything with more than one
    /// card is structured.
    static func workoutType(for segments: [ActivitySegment]) -> WorkoutType {
        guard segments.count == 1, let s = segments.first else {
            return segments.isEmpty ? .free : .custom
        }
        switch s.goal {
        case .none:      return .free
        case .distance:  return .distance
        case .time:      return .time
        case .pace:      return .pace
        case .heartRate: return .heartRate
        case .intervals: return .intervals
        }
    }
}
