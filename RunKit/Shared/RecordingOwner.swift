import Foundation
import Observation

/// Tracks whether the *other* device is currently recording.
///
/// Both the phone and the watch can record a run, and they must never do it at the
/// same time: two recordings of one run means two workouts in Apple Health and
/// double the active energy, which then flows into FuelKit as real intake headroom.
/// Deduplicating afterwards is not possible — by then there are two legitimate-
/// looking workouts from two sources.
///
/// The rule is simply **whichever device you tapped Start on owns the session**. The
/// other one says so and offers nothing else.
///
/// ## What this can and cannot do
///
/// It is a courtesy signal over `sendMessage`, which only arrives when the two
/// devices are in contact. Out of range, neither knows about the other and both
/// will happily record. That is *correct* for the case this exists to serve — the
/// watch going out alone — and the realistic failure it prevents is the common one:
/// both devices on you, and you forget the watch is already going.
///
/// So this is a guard, not a lock. It deliberately does not block recording; it
/// tells the user what's already running and lets them decide. A hard block that
/// depended on connectivity would strand someone whose watch was out of range.
@Observable
final class RecordingOwner {
    static let shared = RecordingOwner()

    /// Set when the counterpart device says it started, cleared when it says it
    /// stopped — or when the claim goes stale.
    private(set) var remoteLabel: String?
    private var claimedAt: Date?

    /// A claim older than this is ignored. The stop message is the normal way a
    /// claim ends, but it can be missed — the app can be killed, or the devices can
    /// separate mid-run — and a stuck "recording on your Watch" banner that never
    /// clears would be worse than the problem it warns about.
    private let staleAfter: TimeInterval = 4 * 60 * 60

    var isRemoteRecording: Bool {
        guard let claimedAt, remoteLabel != nil else { return false }
        return Date().timeIntervalSince(claimedAt) < staleAfter
    }

    func remoteDidStart(label: String) {
        remoteLabel = label
        claimedAt = Date()
    }

    func remoteDidStop() {
        remoteLabel = nil
        claimedAt = nil
    }

    /// Decodes the counterpart's message. Returns true when it was one of ours.
    @discardableResult
    func handle(message: [String: Any]) -> Bool {
        guard let recording = message[WatchLink.recordingKey] as? Bool else { return false }
        if recording {
            remoteDidStart(label: message[WatchLink.recordingLabelKey] as? String ?? "a run")
        } else {
            remoteDidStop()
        }
        return true
    }

    static func message(recording: Bool, label: String) -> [String: Any] {
        [WatchLink.recordingKey: recording, WatchLink.recordingLabelKey: label]
    }
}
