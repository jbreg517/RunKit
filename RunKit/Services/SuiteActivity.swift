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
//   • **This file** — *derived* training load / recovery signals, *planned*
//     sessions, and *weighted carries*. None is expressible in HealthKit: it records
//     what happened, not how hard it felt relative to your norm, not what you intend
//     to do tomorrow, and it has no concept of external load at all — a 20 kg ruck
//     and an empty-handed walk are the same workout to Health. See `SuiteCarry`.
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
    /// Absolute active energy burned that day (kcal). Unlike `load`, this is a real
    /// number, published so FuelKit can subtract exercise burn **when HealthKit is
    /// off** (the App-Group fallback in the precedence rule). When Health is on,
    /// HealthKit's own sum wins and this is ignored, so the two never double-count.
    var activeKcal: Double = 0
    /// Total active minutes that day. Absolute, like `activeKcal`.
    ///
    /// Published even though HealthKit records workout duration, because reading it
    /// from Health needs `HKObjectType.workoutType()` — a permission scope an app
    /// shouldn't have to request just to draw a "minutes trained" row.
    var activeMinutes: Double = 0
    /// Session-RPE load in AU: the day's sessions, each `RPE × active minutes`, summed.
    /// 0 when the producer has no effort rating for that day.
    ///
    /// **Summed per session by the producer, and summed again across producers by the
    /// reader.** That is the only form that merges correctly — multiplying a merged
    /// `perceivedEffort` by a merged `activeMinutes` would not give the same answer,
    /// because effort maxes and minutes add.
    ///
    /// Distinct from `load`: this is an absolute figure on a scale shared by everyone,
    /// where `load` is normalised against the individual's own recent norm.
    var sessionLoad: Double = 0

    init(date: Date = Date(), kind: SuiteSessionKind = .rest, load: Double = 0,
         perceivedEffort: Double = 0, sessionCount: Int = 0, activeKcal: Double = 0,
         activeMinutes: Double = 0, sessionLoad: Double = 0) {
        self.date = date
        self.kind = kind
        self.load = load
        self.perceivedEffort = perceivedEffort
        self.sessionCount = sessionCount
        self.activeKcal = activeKcal
        self.activeMinutes = activeMinutes
        self.sessionLoad = sessionLoad
    }

    /// Every field optional on the wire — see the note on `SuiteProfile.init(from:)`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date            = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        kind            = try c.decodeIfPresent(SuiteSessionKind.self, forKey: .kind) ?? .rest
        load            = try c.decodeIfPresent(Double.self, forKey: .load) ?? 0
        perceivedEffort = try c.decodeIfPresent(Double.self, forKey: .perceivedEffort) ?? 0
        sessionCount    = try c.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
        activeKcal      = try c.decodeIfPresent(Double.self, forKey: .activeKcal) ?? 0
        activeMinutes   = try c.decodeIfPresent(Double.self, forKey: .activeMinutes) ?? 0
        sessionLoad     = try c.decodeIfPresent(Double.self, forKey: .sessionLoad) ?? 0
    }
}

enum SuiteCarryKind: String, Codable {
    /// Weight carried on the back over ground — a ruck.
    case ruck
    /// Weight carried in the hands or on the shoulders — farmer's, suitcase, yoke.
    case carry
    /// Weight pushed or dragged rather than transported — sled, prowler.
    case sled
    /// A kind this build predates.
    case other

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = SuiteCarryKind(rawValue: raw) ?? .other
    }
}

/// One weighted carry — a ruck, a farmer's walk, a sled push.
///
/// **This is the exception to "never duplicate HealthKit here", and deliberately so.**
/// A ruck saves to Health as an ordinary walk; Health has no concept of external
/// load, so the weight would be lost on the way. RunKit does also attach it to the
/// workout as custom metadata (`SuiteCarry.healthMetadataKey`), but reading that back
/// costs the reader a full `HKObjectType.workoutType()` permission and a query per
/// workout. This channel carries it plainly.
///
/// Absolute and auditable, unlike `SuiteDailyLoad.load` — a strength app folding
/// carries into its own volume needs kilograms and kilometres, not a 0–1 judgement.
///
/// One entry per session, not per day. Loads don't average meaningfully: a 10 kg
/// hour and a 30 kg twenty minutes are different training, and collapsing them to
/// "20 kg" would describe a session nobody did.
struct SuiteCarry: Codable, Equatable, Identifiable {
    /// Stable across republishes, so a reader can deduplicate and can hold its own
    /// annotations against a carry.
    var id: UUID = UUID()
    /// When it started — the actual time, not the start of day, because a reader may
    /// want to place it against the rest of that day's training.
    var startedAt: Date = Date()
    var kind: SuiteCarryKind = .ruck
    /// Short human label ("Morning ruck", "Farmer's 4×40 m").
    var title: String = ""
    /// External weight carried, in kilograms. Always kg on the wire whatever the
    /// producing app displays.
    var loadKg: Double = 0
    /// The user's bodyweight at the time, in kg, or 0 when unknown. Snapshotted so
    /// load-as-a-share-of-bodyweight stays correct after they gain or lose weight.
    var bodyweightKg: Double = 0
    var minutes: Double = 0
    /// 0 for a carry measured only in time, which is normal in a gym.
    var kilometers: Double = 0

    /// The tonnage analogue: kilograms moved over distance. The natural unit for
    /// comparing rucks, and for adding them to a strength app's volume view.
    var kgKilometers: Double { loadKg * kilometers }
    /// Time under load. The only volume figure available for a distance-less carry,
    /// so a reader that wants one number across both should use this.
    var kgMinutes: Double { loadKg * minutes }
    /// Load as a share of bodyweight (0.25 = a quarter of bodyweight), or nil when
    /// no bodyweight was recorded.
    var loadRatio: Double? {
        guard bodyweightKg > 0, loadKg > 0 else { return nil }
        return loadKg / bodyweightKg
    }

    /// The custom HealthKit workout metadata key the suite uses for the same figure.
    /// Anything reading workouts directly can pick the load up from there.
    static let healthMetadataKey = "com.ferrixguild.suite.externalLoadKg"

    init(id: UUID = UUID(), startedAt: Date = Date(), kind: SuiteCarryKind = .ruck,
         title: String = "", loadKg: Double = 0, bodyweightKg: Double = 0,
         minutes: Double = 0, kilometers: Double = 0) {
        self.id = id
        self.startedAt = startedAt
        self.kind = kind
        self.title = title
        self.loadKg = loadKg
        self.bodyweightKg = bodyweightKg
        self.minutes = minutes
        self.kilometers = kilometers
    }

    /// Every field optional on the wire — see the note on `SuiteProfile.init(from:)`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startedAt    = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        kind         = try c.decodeIfPresent(SuiteCarryKind.self, forKey: .kind) ?? .other
        title        = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        loadKg       = try c.decodeIfPresent(Double.self, forKey: .loadKg) ?? 0
        bodyweightKg = try c.decodeIfPresent(Double.self, forKey: .bodyweightKg) ?? 0
        minutes      = try c.decodeIfPresent(Double.self, forKey: .minutes) ?? 0
        kilometers   = try c.decodeIfPresent(Double.self, forKey: .kilometers) ?? 0
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
    /// Weighted carries in the same history window, one entry per session.
    var carries: [SuiteCarry] = []

    static let historyWindow = 14
    static let planWindow = 14

    init(source: SuiteSource = .fuelkit, updatedAt: Date = .distantPast,
         recentLoad: [SuiteDailyLoad] = [], planned: [SuitePlannedSession] = [],
         carries: [SuiteCarry] = []) {
        self.source = source
        self.updatedAt = updatedAt
        self.recentLoad = recentLoad
        self.planned = planned
        self.carries = carries
    }

    /// Every field optional on the wire — see the note on `SuiteProfile.init(from:)`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source     = try c.decodeIfPresent(SuiteSource.self, forKey: .source) ?? .unknown
        updatedAt  = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        recentLoad = try c.decodeIfPresent([SuiteDailyLoad].self, forKey: .recentLoad) ?? []
        planned    = try c.decodeIfPresent([SuitePlannedSession].self, forKey: .planned) ?? []
        carries    = try c.decodeIfPresent([SuiteCarry].self, forKey: .carries) ?? []
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
        // Carries carry a real timestamp rather than a start of day, so the lower
        // bound is the same `earliest` but the upper bound is now — not `today`,
        // which would drop everything done since midnight.
        trimmed.carries = feed.carries
            .filter { $0.startedAt >= earliest && $0.startedAt <= Date() }
            .sorted { $0.startedAt < $1.startedAt }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults.set(data, forKey: key(for: trimmed.source))
        SuiteNotifier.post()   // nudge running sibling apps to refresh at once
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
    /// highest RPE wins, because perceived effort doesn't sum — but `sessionLoad` does,
    /// which is exactly why it's carried as its own field rather than recomputed from
    /// the merged RPE and minutes.
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
            merged.activeKcal += entry.activeKcal   // absolute kcal sums (FuelKit's Health-off fallback)
            merged.activeMinutes += entry.activeMinutes
            merged.sessionLoad += entry.sessionLoad
            if merged.kind == .rest { merged.kind = entry.kind }
        }
        return merged
    }

    // MARK: - Weighted carries

    /// Every weighted carry the other apps have published, oldest first.
    ///
    /// This is how a strength app folds rucking into its own volume tracking without
    /// asking for HealthKit workout permission: RunKit publishes each ruck here, and
    /// LiftKit reads kilograms and kilometres straight off it.
    static func carries(excluding own: SuiteSource, since: Date? = nil) -> [SuiteCarry] {
        feeds(excluding: own)
            .flatMap(\.carries)
            // Not `since.map { start in $0.startedAt >= start }`: `$0` inside a closure that
            // already names its own argument is a compile error, and it read as though the
            // two referred to the same thing.
            .filter { carry in
                guard let since else { return true }
                return carry.startedAt >= since
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Total weighted-carry volume over a window, or **nil when nobody reported any
    /// carries** — the same distinction `totalLoad` draws. Zero carries and "no app
    /// that records carries is installed" must not look alike to a reader deciding
    /// whether to show a volume figure at all.
    ///
    /// `kgKilometers` and `kgMinutes` both add up across sessions, which is the whole
    /// reason they are the published quantities rather than a merged average load.
    static func carryVolume(excluding own: SuiteSource, since: Date? = nil)
        -> (sessions: Int, kgKilometers: Double, kgMinutes: Double, heaviestKg: Double)? {
        let entries = carries(excluding: own, since: since)
        guard !entries.isEmpty else { return nil }
        return (sessions: entries.count,
                kgKilometers: entries.reduce(0) { $0 + $1.kgKilometers },
                kgMinutes: entries.reduce(0) { $0 + $1.kgMinutes },
                heaviestKg: entries.map(\.loadKg).max() ?? 0)
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

// MARK: - Cross-process change signal
//
// App Group `UserDefaults` writes don't notify other processes, so a sibling app
// only picked up changes on its next foreground. This posts a Darwin notification
// on every shared write (profile or activity); running apps refresh immediately —
// which matters in iPad Split View / Slide Over where two suite apps are visible at
// once. Byte-identical across the three apps (part of the shared `SuiteActivity`
// contract).
enum SuiteNotifier {
    /// Name of the cross-process Darwin signal.
    private static let darwinName = "com.ferrixguild.suite.changed"
    /// Local `NotificationCenter` name views observe (the Darwin callback is a bare C
    /// function pointer that can't capture context, so it's bridged to this).
    static let changed = Notification.Name("com.ferrixguild.suite.changed.local")
    private static var bridging = false

    /// Post after writing shared App Group data (profile or activity).
    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinName as CFString), nil, nil, true)
    }

    /// Bridge the Darwin signal to `SuiteNotifier.changed`. Call once at launch;
    /// idempotent. Views then observe `SuiteNotifier.changed` to refresh.
    static func startBridging() {
        guard !bridging else { return }
        bridging = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: SuiteNotifier.changed, object: nil)
            },
            darwinName as CFString, nil, .deliverImmediately)
    }
}
