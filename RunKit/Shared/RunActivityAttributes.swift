import ActivityKit
import Foundation

/// Shared between the app and the widget extension (member of both targets).
/// The elapsed timer is driven by `startDate` via `Text(timerInterval:)` in the
/// widget, so the app only has to push the values that actually change — not every
/// second.
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var distanceText: String = "0.00 km"   // e.g. "5.2 km"
        /// Pace right now, already formatted — "5:42 /km", or a speed on a ride.
        /// "--" while stopped or before GPS has a usable reading.
        var paceText: String = "--"
        /// Pace over the whole session so far, same formatting.
        var avgPaceText: String = "--"
        /// What the two above are: "pace" on foot, "speed" on a ride. Carried
        /// rather than derived from `activityLabel`, because a card-based workout
        /// can switch activity mid-session.
        var paceLabel: String = "pace"
        var detailText: String = ""            // e.g. "WORK · 3/8", or ""

        init(distanceText: String = "0.00 km", paceText: String = "--",
             avgPaceText: String = "--", paceLabel: String = "pace",
             detailText: String = "") {
            self.distanceText = distanceText
            self.paceText = paceText
            self.avgPaceText = avgPaceText
            self.paceLabel = paceLabel
            self.detailText = detailText
        }

        /// Every field optional on the wire. A Live Activity started by one build
        /// can outlive an app update, and the synthesized decoder throws on any
        /// absent key — which would leave a stuck activity the app can no longer
        /// update or end.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            distanceText = try c.decodeIfPresent(String.self, forKey: .distanceText) ?? "0.00 km"
            paceText     = try c.decodeIfPresent(String.self, forKey: .paceText) ?? "--"
            avgPaceText  = try c.decodeIfPresent(String.self, forKey: .avgPaceText) ?? "--"
            paceLabel    = try c.decodeIfPresent(String.self, forKey: .paceLabel) ?? "pace"
            detailText   = try c.decodeIfPresent(String.self, forKey: .detailText) ?? ""
        }
    }

    var activityLabel: String      // "Run" / "Walk" / "Ride"
    var startDate: Date
}
