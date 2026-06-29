import Foundation
import SwiftData

@Model
final class ActivitySession {
    var id: UUID = UUID()
    var typeRaw: String = ActivityType.walk.rawValue
    var startedAt: Date = Date()
    var endedAt: Date?
    /// Active seconds (excludes pauses — RunKit sessions don't pause yet).
    var activeSeconds: TimeInterval = 0
    var distanceMeters: Double = 0
    var steps: Int = 0
    var flights: Int = 0
    var activeEnergyKcal: Double = 0
    var usedGPS: Bool = false
    var manualDistance: Bool = false
    /// True when some of `distanceMeters` came from a fallback (pedometer fill or
    /// a straight-line GPS-gap bridge) rather than a clean GPS track.
    var distanceEstimated: Bool = false
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.session)
    var route: [RoutePoint] = []

    init(type: ActivityType, startedAt: Date = Date()) {
        self.typeRaw = type.rawValue
        self.startedAt = startedAt
    }

    var type: ActivityType { ActivityType(rawValue: typeRaw) ?? .walk }
    var sortedRoute: [RoutePoint] { route.sorted { $0.timestamp < $1.timestamp } }
}
