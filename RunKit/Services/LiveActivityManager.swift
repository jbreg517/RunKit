import ActivityKit
import Foundation

/// Starts/updates/ends the run Live Activity (Dynamic Island + lock screen).
/// Everything is local (no push), so no server and no push entitlement — in line
/// with RunKit's privacy stance. No-ops gracefully if Live Activities are disabled.
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<RunActivityAttributes>?

    func start(label: String, startDate: Date, distanceText: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let attributes = RunActivityAttributes(activityLabel: label, startDate: startDate)
        let state = RunActivityAttributes.ContentState(distanceText: distanceText, detailText: detail)
        activity = try? Activity.request(attributes: attributes,
                                         content: .init(state: state, staleDate: nil))
    }

    func update(distanceText: String, detail: String) {
        guard let activity else { return }
        let state = RunActivityAttributes.ContentState(distanceText: distanceText, detailText: detail)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
