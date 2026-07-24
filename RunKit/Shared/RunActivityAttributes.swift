import ActivityKit
import Foundation

/// Shared between the app and the widget extension (member of both targets).
/// The elapsed timer is driven by `startDate` via `Text(timerInterval:)` in the
/// widget, so the app only has to push distance/detail — not every second.
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var distanceText: String   // e.g. "5.2 km"
        var detailText: String     // e.g. "WORK · 3/8", a pace, or ""
    }

    var activityLabel: String      // "Run" / "Walk" / "Ride"
    var startDate: Date
}
