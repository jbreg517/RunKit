import Foundation
import Observation

/// App-wide navigation state shared via the environment. Lets a detail screen in
/// one tab (e.g. "Do Again" in History) start a session without coupling the
/// views together.
@Observable
final class AppRouter {
    enum Tab: Hashable { case today, history, settings }

    var selectedTab: Tab = .today

    /// Prefills the session screen's type; consumed there once.
    var pendingActivityType: ActivityType?

    /// Drives the Activity screen. Activity is no longer a tab — it's presented
    /// full-screen from the Start Run button (and from "Do Again"), so a running
    /// session owns the whole screen instead of competing with a tab bar.
    var showActivity = false

    /// Present the session screen, optionally preselecting a type.
    func startRun(_ type: ActivityType? = nil) {
        pendingActivityType = type
        showActivity = true
    }

    func doAgain(_ type: ActivityType) { startRun(type) }
}
