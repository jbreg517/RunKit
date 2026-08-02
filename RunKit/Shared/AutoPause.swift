import Foundation

/// Decides when a run has actually stopped, and when it has started again.
///
/// Shared by the phone and the watch so both devices pause at the same moment —
/// otherwise the same traffic light produces two different average paces depending
/// on which device recorded it.
///
/// Two guards against flapping, which is the failure mode that makes auto-pause
/// worse than not having it:
///
/// 1. **Hysteresis.** The speed that stops you is well below the speed that starts
///    you again, so hovering at one threshold can't toggle the state repeatedly.
/// 2. **Dwell.** Each transition has to hold for a few seconds. A single bad GPS
///    fix — which is common the moment you stop moving and the receiver starts
///    wandering — can't pause a run on its own.
///
/// Thresholds are per activity: 0.5 m/s means "stopped" to a runner and "strolling"
/// to a walker, and applying one number to both would pause every slow walk.
struct AutoPauseDetector {

    enum Action { case none, pause, resume }

    /// Below this for `stopAfter` seconds → pause.
    var stopBelow: Double
    /// Above this for `resumeAfter` seconds → resume.
    var resumeAbove: Double
    var stopAfter: TimeInterval
    var resumeAfter: TimeInterval

    private var slowSince: Date?
    private var fastSince: Date?

    init(stopBelow: Double, resumeAbove: Double,
         stopAfter: TimeInterval = 5, resumeAfter: TimeInterval = 2) {
        self.stopBelow = stopBelow
        self.resumeAbove = resumeAbove
        self.stopAfter = stopAfter
        self.resumeAfter = resumeAfter
    }

    /// A walker's "stopped" is much slower than a runner's, and a cyclist coasting
    /// to a halt needs a higher restart bar so freewheeling doesn't resume early.
    static func forActivity(_ activity: ActivityType) -> AutoPauseDetector {
        switch activity {
        case .walk: return AutoPauseDetector(stopBelow: 0.3, resumeAbove: 0.6)
        case .run:  return AutoPauseDetector(stopBelow: 0.5, resumeAbove: 1.2)
        case .ride: return AutoPauseDetector(stopBelow: 0.5, resumeAbove: 1.5)
        }
    }

    /// - Parameters:
    ///   - speedMps: current speed. Must keep being measured **while auto-paused**,
    ///     or nothing can ever resume.
    ///   - autoPaused: whether we're currently in an auto-pause.
    /// - Returns: the transition to make, if any.
    mutating func update(speedMps: Double, autoPaused: Bool, now: Date = Date()) -> Action {
        if autoPaused {
            slowSince = nil
            guard speedMps > resumeAbove else {
                fastSince = nil
                return .none
            }
            let since = fastSince ?? now
            fastSince = since
            guard now.timeIntervalSince(since) >= resumeAfter else { return .none }
            fastSince = nil
            return .resume
        }

        fastSince = nil
        guard speedMps < stopBelow else {
            slowSince = nil
            return .none
        }
        let since = slowSince ?? now
        slowSince = since
        guard now.timeIntervalSince(since) >= stopAfter else { return .none }
        slowSince = nil
        return .pause
    }

    /// Clears both dwell timers. Call whenever the session is paused or resumed by
    /// hand, so a manual action doesn't leave a half-elapsed timer that fires
    /// immediately afterwards.
    mutating func reset() {
        slowSince = nil
        fastSince = nil
    }
}
