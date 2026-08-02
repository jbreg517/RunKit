import Foundation

/// What the watch shows on its menu. Member of both the iOS app and the watch app
/// targets.
///
/// Because the watch **records the run itself**, this carries the real
/// `ActivitySegment` cards rather than a description of them — the wrist runs the
/// same card semantics as the phone, from the same source file, so the two can't
/// drift. What it deliberately does *not* carry is any SwiftData type:
/// `CustomWorkout` and `ScheduledRun` stay on the phone, and the watch refers back
/// to them by id only.
struct WatchMenu: Codable, Hashable {

    /// One runnable thing on the watch: the cards to run, plus the identity the
    /// phone needs to reconcile the finished session against what was planned.
    struct Item: Codable, Hashable, Identifiable {

        /// Where this came from, so a finished run can be tied back to it.
        enum Source: String, Codable, CaseIterable {
            case recipe     // a `WorkoutRecipe`, by name
            case custom     // a saved `CustomWorkout`, by id
            case scheduled  // a `ScheduledRun` due today, by id — gets ticked off
            case quick      // no saved workout at all, just an activity type
        }

        var id: UUID = UUID()
        var name: String = ""
        /// The cards to run. Never empty in practice — a plain run is one open card.
        var segments: [ActivitySegment] = []
        /// `Source.rawValue`. Kept as a string so a source this watch build doesn't
        /// know yet degrades to a default instead of failing the whole decode.
        var sourceRaw: String = Source.recipe.rawValue
        /// `WorkoutRecipe.Category.rawValue`, for grouping the prebuilt list. Empty
        /// for everything else.
        var category: String = ""
        /// `WorkoutRecipe.name` when `source == .recipe`.
        var recipeName: String = ""
        /// The `CustomWorkout` or `ScheduledRun` id, per `source`.
        var referenceID: UUID?

        var source: Source { Source(rawValue: sourceRaw) ?? .recipe }

        /// Leading activity, used for the row icon and the HealthKit workout type.
        var activity: ActivityType { segments.first?.activity ?? .run }

        /// The one-line description under the row. Computed here rather than sent
        /// pre-formatted, because the watch now holds both the cards and the unit
        /// preference — so there's nothing to gain from formatting twice.
        func summary(_ unit: UnitSystem) -> String {
            if segments.count > 1 {
                return "\(segments.count) cards · \(segments[0].summary(unit))"
            }
            return segments.first?.summary(unit) ?? "Open run"
        }

        init(id: UUID = UUID(), name: String = "", segments: [ActivitySegment] = [],
             source: Source = .recipe, category: String = "",
             recipeName: String = "", referenceID: UUID? = nil) {
            self.id = id
            self.name = name
            self.segments = segments
            self.sourceRaw = source.rawValue
            self.category = category
            self.recipeName = recipeName
            self.referenceID = referenceID
        }

        /// Every field optional on the wire. The watch app and the phone app update
        /// **independently** — a watch running last month's build will be handed
        /// today's payload — and a synthesized decoder throws on any absent key,
        /// which would empty the menu rather than degrade it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            segments = try c.decodeIfPresent([ActivitySegment].self, forKey: .segments) ?? []
            sourceRaw = try c.decodeIfPresent(String.self, forKey: .sourceRaw) ?? Source.recipe.rawValue
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
            recipeName = try c.decodeIfPresent(String.self, forKey: .recipeName) ?? ""
            referenceID = try c.decodeIfPresent(UUID.self, forKey: .referenceID)
        }
    }

    /// `UnitSystem.rawValue` — the watch formats its own strings, but the choice is
    /// still the phone's to make.
    var unitRaw: String = UnitSystem.metric.rawValue
    /// Due today or carried forward from a missed day — what the watch suggests.
    var scheduledToday: [Item] = []
    /// The prebuilt library, sent rather than compiled into the watch so the
    /// catalogue has exactly one source of truth.
    var recipes: [Item] = []
    /// The user's saved workouts, favourites first.
    var custom: [Item] = []
    /// Heart-rate zone inputs, resolved on the phone — it's the side with the user's
    /// max-HR override, their age from the suite profile, and a resting HR from
    /// Health. The watch derives the five zone bounds from these so a heart-rate
    /// card is judged against the same numbers on both devices.
    var maxHR: Double = 0
    var restingHR: Double = 0

    var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    /// The zone bounds a heart-rate card is judged against. Empty when the phone has
    /// never synced a max HR, which the caller must treat as "don't nudge" rather
    /// than as zone 1.
    var zones: [HeartRateZones.Zone] {
        guard maxHR > 0 else { return [] }
        return HeartRateZones.zones(maxHR: maxHR, restingHR: restingHR > 0 ? restingHR : nil)
    }

    init(unitRaw: String = UnitSystem.metric.rawValue,
         scheduledToday: [Item] = [], recipes: [Item] = [], custom: [Item] = [],
         maxHR: Double = 0, restingHR: Double = 0) {
        self.unitRaw = unitRaw
        self.scheduledToday = scheduledToday
        self.recipes = recipes
        self.custom = custom
        self.maxHR = maxHR
        self.restingHR = restingHR
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unitRaw = try c.decodeIfPresent(String.self, forKey: .unitRaw) ?? UnitSystem.metric.rawValue
        scheduledToday = try c.decodeIfPresent([Item].self, forKey: .scheduledToday) ?? []
        recipes = try c.decodeIfPresent([Item].self, forKey: .recipes) ?? []
        custom = try c.decodeIfPresent([Item].self, forKey: .custom) ?? []
        maxHR = try c.decodeIfPresent(Double.self, forKey: .maxHR) ?? 0
        restingHR = try c.decodeIfPresent(Double.self, forKey: .restingHR) ?? 0
    }

    /// A plain open run of the given activity — the "Start Run" button, and the
    /// fallback the watch offers before it has ever synced.
    static func quick(_ activity: ActivityType) -> Item {
        Item(name: activity.rawValue,
             segments: [ActivitySegment(activity: activity, goal: .none)],
             source: .quick)
    }
}

// MARK: - Transport

/// The WatchConnectivity dictionary keys, in one place so the two sides can't drift.
enum WatchLink {
    /// Application-context key carrying an encoded `WatchMenu`.
    static let menuKey = "menu"
    /// Message key: `true` while that device has a live recording.
    ///
    /// Deliberately a *message*, not application context. This is an event with a
    /// short useful life — "I started, don't you start too" — and application
    /// context is retained and replayed, which would leave a device believing the
    /// other was still recording a run that ended hours ago.
    static let recordingKey = "recording"
    /// Message key carried alongside `recordingKey`: what's being recorded, for the
    /// banner text.
    static let recordingLabelKey = "recordingLabel"
    /// Filename prefix for a transferred `WatchSessionPayload`.
    static let sessionFilePrefix = "runkit-session-"

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from any: Any?) -> T? {
        guard let data = any as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
