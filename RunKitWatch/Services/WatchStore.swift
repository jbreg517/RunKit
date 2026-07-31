import Foundation
import Observation
import WatchConnectivity

/// The watch half of the link: holds the menu the phone last sent, and asks the
/// phone to start a run.
///
/// No local persistence of its own — `WCSession.receivedApplicationContext` already
/// survives relaunch, so the last menu is on disk for free and there is no second
/// copy to fall out of step with the first.
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    /// What the phone last sent. Empty until the first sync.
    private(set) var menu = WatchMenu()
    /// True once any menu has arrived — distinguishes "nothing scheduled, no saved
    /// workouts" from "never synced", which need different empty states.
    private(set) var hasSynced = false
    /// Whether the phone can be reached *right now*. Drives whether Start is
    /// offered at all, rather than letting the user tap into a failure.
    private(set) var isReachable = false

    /// Outcome of the last start request, for the confirmation screen.
    enum StartState: Equatable { case idle, sending, started, failed(String) }
    var startState: StartState = .idle

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        } else {
            adopt(session.receivedApplicationContext)
            isReachable = session.isReachable
        }
    }

    /// Ask the phone to start this workout.
    ///
    /// `sendMessage` only, never `transferUserInfo`: a queued start arriving after
    /// the user has given up and put the watch away would begin recording a run
    /// nobody is on. Failing now, visibly, is the correct outcome.
    func requestStart(_ item: WatchMenu.Item) {
        guard let session, session.activationState == .activated else {
            startState = .failed("Watch not connected")
            return
        }
        guard session.isReachable else {
            startState = .failed("iPhone unreachable")
            return
        }
        guard let data = WatchLink.encode(item) else {
            startState = .failed("Couldn’t send")
            return
        }
        startState = .sending
        session.sendMessage([WatchLink.startKey: data]) { reply in
            let accepted = reply[WatchLink.acceptedKey] as? Bool ?? false
            DispatchQueue.main.async {
                self.startState = accepted ? .started : .failed("iPhone couldn’t start it")
            }
        } errorHandler: { _ in
            DispatchQueue.main.async {
                self.startState = .failed("iPhone unreachable")
            }
        }
    }

    func resetStartState() { startState = .idle }

    /// Decodes a context payload into the published menu. Ignores anything it can't
    /// read, so a malformed or future payload leaves the last good menu in place
    /// rather than blanking the screen.
    private func adopt(_ context: [String: Any]) {
        guard let decoded = WatchLink.decode(WatchMenu.self, from: context[WatchLink.menuKey]) else { return }
        DispatchQueue.main.async {
            self.menu = decoded
            self.hasSynced = true
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchStore: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        guard state == .activated else { return }
        // The context the system was already holding — this is what makes the menu
        // present on launch instead of blank until the phone next pushes.
        adopt(session.receivedApplicationContext)
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        adopt(context)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }
}
