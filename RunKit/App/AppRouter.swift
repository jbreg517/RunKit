import Foundation
import Observation

/// App-wide navigation state shared via the environment. Lets a detail screen in
/// one tab (e.g. "Do Again" in History) drive another tab (start a new session in
/// Activity) without coupling the views together.
@Observable
final class AppRouter {
    enum Tab: Hashable { case today, activity, history, settings }

    var selectedTab: Tab = .today

    /// Set by "Do Again" to prefill the Activity tab's type; consumed there once.
    var pendingActivityType: ActivityType?

    /// Switch to the Activity tab and preselect `type` for a fresh session.
    func doAgain(_ type: ActivityType) {
        pendingActivityType = type
        selectedTab = .activity
    }
}
