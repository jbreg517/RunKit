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
