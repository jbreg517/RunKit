import Foundation

// MARK: - Suite-shared health profile (LiftKit / RunKit / FuelKit)
//
// The Ferrixguild fitness suite shares one health profile across its apps:
//   • Height & weight are native Apple Health types (`.height` / `.bodyMass`),
//     so they interoperate through HealthKit with any Health app. They're
//     mirrored here too as a fallback when the user hasn't granted Health.
//   • The *goal* and nutrition targets are NOT HealthKit concepts, so they're
//     shared through a common App Group container instead.
//
// This struct + its property names + the App Group id must match byte-for-byte
// across all three apps (Codable uses the property names as JSON keys). String
// fields carry the same raw values LiftKit uses for its BiologicalSex /
// WeightGoalType / ActivityLevel enums.

struct SuiteProfile: Codable, Equatable {
    // Measurements (Apple Health is the source of truth; mirrored for fallback)
    var heightInches: Double = 0
    var age: Int = 0
    var biologicalSex: String = "unspecified"
    var latestWeightLb: Double = 0

    // Goal + nutrition targets (shared only through the App Group)
    var goalType: String = "maintain"
    var goalWeightLb: Double = 0
    var weeklyRateLb: Double = 1.0
    var activityLevel: String = "moderate"
    var proteinPerLb: Double = 0.8
    var fatPercent: Double = 0.30

    /// When this was last written, so a reader can tell who is newest.
    var updatedAt: Date = .distantPast

    init() {}

    /// Hand-written so **every field is optional on the wire**.
    ///
    /// This matters because the suite apps ship independently and some may not be
    /// installed at all. Swift's synthesized `init(from:)` calls `decode(_:forKey:)`
    /// for non-optional properties, which **throws when a key is absent** — property
    /// default values are not consulted. So the first app to add a field here would
    /// make every not-yet-updated app's decode throw, and since callers use `try?`,
    /// they'd silently treat the shared profile as missing and quietly stop honouring
    /// the user's goal.
    ///
    /// `decodeIfPresent` with a default makes the format both forward and backward
    /// compatible: old readers ignore new fields, new readers fill in defaults for
    /// fields old writers never wrote. **Add fields only, never rename or remove.**
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heightInches   = try c.decodeIfPresent(Double.self, forKey: .heightInches) ?? 0
        age            = try c.decodeIfPresent(Int.self, forKey: .age) ?? 0
        biologicalSex  = try c.decodeIfPresent(String.self, forKey: .biologicalSex) ?? "unspecified"
        latestWeightLb = try c.decodeIfPresent(Double.self, forKey: .latestWeightLb) ?? 0
        goalType       = try c.decodeIfPresent(String.self, forKey: .goalType) ?? "maintain"
        goalWeightLb   = try c.decodeIfPresent(Double.self, forKey: .goalWeightLb) ?? 0
        weeklyRateLb   = try c.decodeIfPresent(Double.self, forKey: .weeklyRateLb) ?? 1.0
        activityLevel  = try c.decodeIfPresent(String.self, forKey: .activityLevel) ?? "moderate"
        proteinPerLb   = try c.decodeIfPresent(Double.self, forKey: .proteinPerLb) ?? 0.8
        fatPercent     = try c.decodeIfPresent(Double.self, forKey: .fatPercent) ?? 0.30
        updatedAt      = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

/// Reads/writes the one `SuiteProfile` in the shared App Group. Every suite app
/// must list `appGroupID` in its entitlements; without it `defaults` is nil and
/// all calls are safe no-ops.
///
/// TODO(iCloud): mirror to `NSUbiquitousKeyValueStore` once the suite's iCloud is
/// live, so the goal follows across the user's devices.
enum SuiteProfileStore {
    static let appGroupID = "group.com.ferrixguild.suite"
    private static let key = "suiteHealthProfile"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static func load() -> SuiteProfile? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SuiteProfile.self, from: data)
    }

    /// Persists `profile`, stamping `updatedAt`. Best-effort; a missing App Group
    /// (unprovisioned) simply does nothing.
    static func save(_ profile: SuiteProfile) {
        guard let defaults else { return }
        var p = profile
        p.updatedAt = Date()
        if let data = try? JSONEncoder().encode(p) {
            defaults.set(data, forKey: key)
        }
    }
}
