import Foundation

/// What the watch shows on its menu, and what it sends back to ask for a run.
/// Member of both the iOS app and the watch app targets.
///
/// Deliberately its own wire format rather than the app's models. `CustomWorkout`
/// is a SwiftData `@Model` and `ActivitySegment` carries every migration since
/// v0.45; making the watch link against either would drag SwiftData and the whole
/// card engine onto a device that only needs to draw a list. Same boundary
/// reasoning as `SuiteActivity`, and the same rule as the Live Activity: the
/// **phone formats the strings**, the watch just renders them, so units and
/// pace-vs-speed are decided in exactly one place.
struct WatchMenu: Codable, Hashable {

    /// One runnable thing on the watch. Enough to draw a row, plus the identity the
    /// phone needs to rebuild the real workout when the watch asks to start it.
    struct Item: Codable, Hashable, Identifiable {

        /// Where the phone should look this up again.
        enum Source: String, Codable, CaseIterable {
            case recipe     // a `WorkoutRecipe`, matched by name
            case custom     // a saved `CustomWorkout`, matched by id
            case scheduled  // a `ScheduledRun` due today, matched by id
            case quick      // no workout at all — just an activity type
        }

        var id: UUID = UUID()
        var name: String = ""
        /// Pre-formatted, in the user's units — "5.00 km", "8 × 30s / 90s".
        var summary: String = ""
        /// `ActivityType.rawValue`. Kept as a string so a value this watch build
        /// doesn't know yet degrades to a default instead of failing the decode.
        var activityRaw: String = "Run"
        /// `Source.rawValue`, string for the same reason.
        var sourceRaw: String = Source.recipe.rawValue
        /// `WorkoutRecipe.Category.rawValue`, for grouping the prebuilt list. Empty
        /// for everything else.
        var category: String = ""
        /// `WorkoutRecipe.name` when `source == .recipe`.
        var recipeName: String = ""
        /// The `CustomWorkout` or `ScheduledRun` id, per `source`.
        var referenceID: UUID?

        var source: Source { Source(rawValue: sourceRaw) ?? .recipe }

        init(id: UUID = UUID(), name: String = "", summary: String = "",
             activityRaw: String = "Run", source: Source = .recipe,
             category: String = "", recipeName: String = "", referenceID: UUID? = nil) {
            self.id = id
            self.name = name
            self.summary = summary
            self.activityRaw = activityRaw
            self.sourceRaw = source.rawValue
            self.category = category
            self.recipeName = recipeName
            self.referenceID = referenceID
        }

        /// Every field optional on the wire. The watch app and the phone app update
        /// **independently** — a watch running last month's build will be handed
        /// today's payload, and a synthesized decoder throws on any absent key,
        /// which would empty the menu rather than degrade it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            activityRaw = try c.decodeIfPresent(String.self, forKey: .activityRaw) ?? "Run"
            sourceRaw = try c.decodeIfPresent(String.self, forKey: .sourceRaw) ?? Source.recipe.rawValue
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
            recipeName = try c.decodeIfPresent(String.self, forKey: .recipeName) ?? ""
            referenceID = try c.decodeIfPresent(UUID.self, forKey: .referenceID)
        }
    }

    /// Due today or carried forward from a missed day — what the watch suggests.
    var scheduledToday: [Item] = []
    /// The prebuilt library. Sent rather than compiled into the watch so the
    /// catalogue has one source of truth and the watch needs no unit formatting.
    var recipes: [Item] = []
    /// The user's saved workouts, favourites first.
    var custom: [Item] = []

    init(scheduledToday: [Item] = [], recipes: [Item] = [], custom: [Item] = []) {
        self.scheduledToday = scheduledToday
        self.recipes = recipes
        self.custom = custom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheduledToday = try c.decodeIfPresent([Item].self, forKey: .scheduledToday) ?? []
        recipes = try c.decodeIfPresent([Item].self, forKey: .recipes) ?? []
        custom = try c.decodeIfPresent([Item].self, forKey: .custom) ?? []
    }

    var isEmpty: Bool { scheduledToday.isEmpty && recipes.isEmpty && custom.isEmpty }
}

// MARK: - Transport

/// The keys used in the WatchConnectivity dictionaries, in one place so the two
/// sides can't drift.
enum WatchLink {
    /// Application-context key carrying an encoded `WatchMenu`.
    static let menuKey = "menu"
    /// Message key carrying an encoded `WatchMenu.Item` the watch wants to start.
    static let startKey = "start"
    /// Reply key: `true` when the phone accepted the start request.
    static let acceptedKey = "accepted"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from any: Any?) -> T? {
        guard let data = any as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
