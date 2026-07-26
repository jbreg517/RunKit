import Foundation
import Observation

/// Live-ish heart rate during a session, for cards with a zone target.
///
/// RunKit has no Watch app of its own, so there is nothing on the wrist to stream
/// from. What it does instead is re-read the trailing HealthKit window every few
/// seconds: a paired Watch recording a workout writes samples continuously, and
/// they land in HealthKit within seconds. That's late enough to be useless for a
/// second-by-second display and perfectly fine for "are you in the right zone",
/// which is the only thing a zone target asks.
///
/// With no Watch, no samples ever arrive, `bpm` stays 0, and the zone card simply
/// runs without nudges rather than failing. When the Watch app lands this class is
/// the seam to replace — the rest of the session code only reads `bpm`.
@Observable
final class LiveHeartRateService {
    static let shared = LiveHeartRateService()

    /// Most recent reading, 0 when nothing is being recorded.
    private(set) var bpm: Double = 0
    /// True once any sample has arrived, so the UI can distinguish "no watch" from
    /// "waiting for the first reading".
    private(set) var hasSource = false

    private var task: Task<Void, Never>?

    /// Sample cadence. Ten seconds keeps the query cost negligible while still
    /// beating the ~25s gap between spoken nudges.
    private static let interval: Duration = .seconds(10)
    /// How far back to look. Long enough to survive a slow Watch write, short
    /// enough that a stale reading can't masquerade as the current one.
    private static let window: TimeInterval = 90

    func start() {
        stop()
        bpm = 0
        hasSource = false
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        bpm = 0
    }

    @MainActor
    private func poll() async {
        let end = Date()
        let samples = await HealthService.shared.heartRateSamples(
            from: end.addingTimeInterval(-Self.window), to: end)
        guard let latest = samples.last else { return }
        bpm = latest.bpm
        hasSource = true
    }
}
