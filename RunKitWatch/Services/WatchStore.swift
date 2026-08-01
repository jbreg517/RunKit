import Foundation
import Observation
import WatchConnectivity

/// Holds the menu the phone last sent.
///
/// No local persistence of its own — `WCSession.receivedApplicationContext` already
/// survives relaunch, so the last menu is on disk for free and there is no second
/// copy to fall out of step with the first.
///
/// The watch records its own runs, so nothing here needs the phone to be reachable.
/// The link is for *syncing what to run*, never for running it.
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    /// What the phone last sent. Empty until the first sync.
    private(set) var menu = WatchMenu()
    /// True once any menu has arrived. Distinguishes "nothing scheduled and no
    /// saved workouts" from "never synced" — different empty states, and telling a
    /// user to open their phone when they've simply saved nothing would be wrong.
    private(set) var hasSynced = false

    var unit: UnitSystem { menu.unit }

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
        }
    }

    /// Queue a finished run for the phone.
    ///
    /// `transferFile`, not `sendMessage`: the run must survive the phone being out
    /// of range for its entire duration, and an hour of route at 1 Hz is past what a
    /// message will carry. The system persists the queue to disk and retries on its
    /// own, so this succeeds even if the phone is left at home all day.
    func send(_ payload: WatchSessionPayload) {
        guard let session, let data = WatchLink.encode(payload) else { return }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(WatchLink.sessionFilePrefix)\(payload.id.uuidString).json")
        do {
            try data.write(to: url)
            session.transferFile(url, metadata: nil)
        } catch {
            // Nothing useful to do — the run is already saved to HealthKit on the
            // watch, so it is not lost, it just won't appear in RunKit's own history.
        }
    }

    /// Decodes a context payload into the published menu. Ignores anything it can't
    /// read, so a malformed or future payload leaves the last good menu in place
    /// rather than blanking the screen mid-run.
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
        // present at launch instead of blank until the phone next pushes.
        adopt(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        adopt(context)
    }

    /// The system copies the file before queueing it, so the temp copy we wrote is
    /// ours to clean up. Left alone these accumulate in the watch's tmp directory.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard error == nil else { return }   // still queued for retry — leave it
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
