import Foundation

// MARK: - Suite activity exchange (LiftKit / RunKit / FuelKit)
//
// The second shared channel, alongside `SuiteProfileStore`. Between them they cover
// everything the suite shares — there is deliberately **no shared database**. Three
// apps writing one SwiftData store is what destroyed FuelKit's food log twice; see
// `FuelKitApp.storeURL`.
//
// What goes where:
//   • **HealthKit** — anything with a native type: workouts, active energy, dietary
//     energy, bodyweight, height. It is the source of truth and interoperates with
//     any Health app. Never duplicate those numbers here; read them from Health.
//   • **SuiteProfileStore** — the goal and nutrition targets, which aren't HealthKit
//     concepts.
//   • **This file** — *derived* training load / recovery signals and *planned*
//     sessions. Neither is expressible in HealthKit: it records what happened, not
//     how hard it felt relative to your norm, and not what you intend to do
//     tomorrow.
//
// Multi-writer safety: each app owns exactly **one key**, `suiteActivityFeed.<source>`,
// and writes only its own. Readers merge across sources. Nothing is ever
// read-modify-written across apps, so two apps can never clobber each other.
//
// This file must match byte-for-byte across all three apps — `Codable` uses the
// property names as JSON keys.

/// Which app produced a feed. Also the key suffix, so it must stay stable.
///
/// Not every app will be installed, and they don't all ship at once. Readers
/// therefore discover feeds by scanning keys rather than iterating this enum, so a
/// future app's feed is consumed by today's builds with no code change.
enum SuiteSource: String, Codable, CaseIterable {
    case liftkit, runkit, fuelkit
    /// A suite app this build predates.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = SuiteSource(rawValue: raw) ?? .unknown
    }
}

enum SuiteSessionKind: String, Codable {
    case strength, cardio, mobility, rest
    /// A kind this build predates — deliberately **not** folded into `rest`, which
    /// would tell a reader the user took a day off when they actually trained.
    case other

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = SuiteSessionKind(rawValue: raw) ?? .other
    }
}

/// One day's derived training load from one app.
///
/// `load` is a normalised 0–1 figure the *producing* app computes against that
/// user's own recent norm — a hard leg day and a long run should both read high.
/// Absolute duration and energy stay in HealthKit; this is the judgement HealthKit
/// can't make.
struct SuiteDailyLoad: Codable, Equatable {
    /// Start of day.
    var date: Date = Date()
    var kind: SuiteSessionKind = .rest
    /// 0 = rest, 1 = the hardest this user does. Producer-normalised.
    var load: Double = 0
    /// Session RPE 1–10 when the user gave one, else 0.
    var perceivedEffort: Double = 0
    var sessionCount: Int = 0

    init(date: Date = Date(), kind: SuiteSessionKind = .rest, load: Double = 0,
         perceivedEffort: Double = 0, sessionCount: Int = 0) {
        self.date = date
        self.kind = kind
        self.load = load
        self.perceivedEffort = perceivedEffort
        self.sessionCount = sessionCount
    }

    /// Every field optional on the wire — see the note on `SuiteProfile.init(from:)`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date            = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        kind            = try c.decodeIfPresent(SuiteSessionKind.self, forKey: .kind) ?? .rest
        load            = try c.decodeIfPresent(Double.self, forKey: .load) ?? 0
        perceivedEffort = try c.decodeIfPresent(Double.self, forKey: .perceivedEffort) ?? 0
        sessionCount    = try c.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
    }
}

/// Something the user intends to do, so other apps can prepare — FuelKit raising
/// carbs the day before a long run, LiftKit backing off after one.
struct SuitePlannedSession: Codable, Equatable {
    var date: Date = Date()
    var kind: SuiteSessionKind = .strength
    /// Short human label ("Long run", "Squat 5×5").
    var title: String = ""
    var plannedMinutes: Int = 0
    /// Expected load on the same 0–1 scale, when the producer can estimate it.
    var plannedLoad: Double = 0

    init(date: Date = Date(), kind: SuiteSessionKind = .strength, title: String = "",
         plannedMinutes: Int = 0, plannedLoad: Double = 0) {
        self.date = date
        self.kind = kind
        self.title = title
        self.plannedMinutes = plannedMinutes
        self.plannedLoad = plannedLoad
    }

    /// Every field optional on the wire — see the note on `SuiteProfile.init(from:)`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date           = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        kind           = try c.decodeIfPresent(SuiteSessionKind.self, forKey: .kind) ?? .strength
        title          = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        plannedMinutes = try c.decodeIfPresent(Int.self, forKey: .plannedMinutes) ?? 0
        plannedLoad    = try c.decodeIfPresent(Double.self, forKey: .plannedLoad) ?? 0
    }
}

/// One app's slice of the exchange. Windows are bounded so the shared defaults stay
/// small: recent load back ~14 days, plans forward ~14 days.
struct SuiteActivityFeed: Codable, Equatable {
    var source: SuiteSource = .fuelkit
    var updatedAt: Date = .distantPast
    var recentLoad: [SuiteDailyLoad] = []
    var planned: [SuitePlannedSession] = []

    static let historyWindow = 14
    static let planWindow = 14

    init(source: SuiteSource = .fuelkit, updatedAt: Date = .distantPast,
         recentLoad: [SuiteDailyLoad] = [], planned: [SuitePlannedSession] = []) {
        self.source = source
        self.updatedAt = updatedAt
        self.recentLoad = recentLoad
        self.planned = planned
    }

    /// Every field optional on the wire — see the note on `SuiteProfile.init(from:)`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source     = try c.decodeIfPresent(SuiteSource.self, forKey: .source) ?? .unknown
        updatedAt  = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        recentLoad = try c.decodeIfPresent([SuiteDailyLoad].self, forKey: .recentLoad) ?? []
        planned    = try c.decodeIfPresent([SuitePlannedSession].self, forKey: .planned) ?? []
    }
}

/// Reads and writes activity feeds in the shared App Group.
///
/// Every suite app must list `SuiteProfileStore.appGroupID` in its entitlements;
/// without it `defaults` is nil and every call is a safe no-op.
enum SuiteActivityStore {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SuiteProfileStore.appGroupID)
    }

    private static func key(for source: SuiteSource) -> String {
        "suiteActivityFeed.\(source.rawValue)"
    }

    /// Publish this app's own feed. Trims both windows before writing so the shared
    /// container can't grow without bound.
    static func publish(_ feed: SuiteActivityFeed) {
        guard let defaults else { return }
        var trimmed = feed
        trimmed.updatedAt = Date()
        let today = Calendar.current.startOfDay(for: Date())
        let earliest = Calendar.current.date(byAdding: .day,
                                             value: -SuiteActivityFeed.historyWindow,
                                             to: today) ?? today
        let latest = Calendar.current.date(byAdding: .day,
                                           value: SuiteActivityFeed.planWindow,
                                           to: today) ?? today
        trimmed.recentLoad = feed.recentLoad
            .filter { $0.date >= earliest && $0.date <= today }
            .sorted { $0.date < $1.date }
        trimmed.planned = feed.planned
            .filter { $0.date >= today && $0.date <= latest }
            .sorted { $0.date < $1.date }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults.set(data, forKey: key(for: trimmed.source))
    }

    /// One app's feed, if it has published one. Nil when that app isn't installed,
    /// hasn't launched, or predates this channel — all normal, none an error.
    static func feed(from source: SuiteSource) -> SuiteActivityFeed? {
        guard let defaults, let data = defaults.data(forKey: key(for: source)) else { return nil }
        guard var feed = try? JSONDecoder().decode(SuiteActivityFeed.self, from: data) else { return nil }
        // The key is the authority on provenance, so a feed written by a build whose
        // `SuiteSource` this one doesn't recognise is still correctly attributed.
        feed.source = source
        return feed
    }

    /// Every published feed except this app's own, found by **scanning keys** rather
    /// than iterating `SuiteSource`. Users won't have every app, and the apps don't
    /// ship together — scanning means a future app's feed is picked up by today's
    /// builds without an update, and a missing app simply contributes nothing.
    static func feeds(excluding own: SuiteSource) -> [SuiteActivityFeed] {
        guard let defaults else { return [] }
        let ownKey = key(for: own)
        return defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(keyPrefix) && $0 != ownKey }
            .sorted()
            .compactMap { storedKey in
                guard let data = defaults.data(forKey: storedKey),
                      var feed = try? JSONDecoder().decode(SuiteActivityFeed.self, from: data)
                else { return nil }
                let suffix = String(storedKey.dropFirst(keyPrefix.count))
                feed.source = SuiteSource(rawValue: suffix) ?? .unknown
                return feed
            }
    }

    private static let keyPrefix = "suiteActivityFeed."

    // MARK: - Merged reads

    /// Combined load for a day across every other app, or **nil when nobody reported
    /// on that day at all**.
    ///
    /// The nil matters. A zero load and "no data" are completely different: if the
    /// user simply doesn't have LiftKit or RunKit installed, a reader must not treat
    /// that as a rest day and cut their calorie target. Callers should change
    /// behaviour only on a value, never on the absence of one.
    ///
    /// Loads add (a lift *and* a run is harder than either alone), capped at 1. The
    /// highest RPE wins, because perceived effort doesn't sum.
    static func totalLoad(on date: Date, excluding own: SuiteSource) -> SuiteDailyLoad? {
        let day = Calendar.current.startOfDay(for: date)
        let entries = feeds(excluding: own)
            .flatMap(\.recentLoad)
            .filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
        guard !entries.isEmpty else { return nil }

        var merged = SuiteDailyLoad(date: day, kind: .rest)
        for entry in entries {
            merged.load = min(1, merged.load + entry.load)
            merged.perceivedEffort = max(merged.perceivedEffort, entry.perceivedEffort)
            merged.sessionCount += entry.sessionCount
            if merged.kind == .rest { merged.kind = entry.kind }
        }
        return merged
    }

    /// Whether any other suite app is publishing at all — the check to make before
    /// building UI that would otherwise claim "rest day" on an empty channel.
    static func hasAnyFeed(excluding own: SuiteSource) -> Bool {
        !feeds(excluding: own).isEmpty
    }

    /// Everything planned from here on, across the other apps, soonest first. Empty
    /// when no other app is installed — which is indistinguishable from "nothing
    /// planned", and harmless, since both mean "don't adjust anything".
    static func upcoming(excluding own: SuiteSource) -> [SuitePlannedSession] {
        let today = Calendar.current.startOfDay(for: Date())
        return feeds(excluding: own)
            .flatMap(\.planned)
            .filter { $0.date >= today }
            .sorted { $0.date < $1.date }
    }
}
