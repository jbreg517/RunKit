import Foundation
import CoreLocation

/// Efficiency Factor and aerobic decoupling — see `docs/ANALYTICS.md` §4b.
///
/// Both compare output against heart rate. **EF** does it across sessions (how
/// far you travel per heartbeat); **decoupling** does it within one (did the
/// ratio hold from the first half to the second). Rising EF and falling
/// decoupling both mean the aerobic base is improving.
enum AerobicAnalysis {

    // MARK: Efficiency Factor

    /// Metres travelled per heartbeat. Deliberately this unit rather than a
    /// unitless ratio — "how far you go per beat" is explainable in one line,
    /// which is the bar every number on the Stats page has to clear.
    ///
    /// Needs only the cached average HR, so it works with no per-sample data.
    static func efficiencyFactor(_ s: ActivitySession) -> Double? {
        guard s.avgHeartRateBpm > 0, s.activeSeconds > 0, s.distanceMeters > 0 else { return nil }
        let beats = s.avgHeartRateBpm * (s.activeSeconds / 60)
        guard beats > 0 else { return nil }
        return s.distanceMeters / beats
    }

    /// Mean EF over sessions that have one, or nil.
    static func averageEfficiencyFactor(_ sessions: [ActivitySession]) -> Double? {
        let values = sessions.compactMap(efficiencyFactor)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Percent change between the older and newer half of a run of sessions.
    /// Positive = improving. Needs ≥4 so a single outlier can't dominate.
    static func efficiencyTrendPercent(_ sessions: [ActivitySession]) -> Double? {
        let ordered = sessions
            .filter { efficiencyFactor($0) != nil }
            .sorted { $0.startedAt < $1.startedAt }
        guard ordered.count >= 4 else { return nil }
        let mid = ordered.count / 2
        guard let older = averageEfficiencyFactor(Array(ordered[..<mid])),
              let newer = averageEfficiencyFactor(Array(ordered[mid...])),
              older > 0 else { return nil }
        return (newer - older) / older * 100
    }

    // MARK: Decoupling

    /// Why a session can't produce a decoupling figure. Showing the reason beats
    /// showing a confident wrong number.
    enum Ineligible: String {
        case tooShort   = "Needs a run of 30 minutes or more"
        case noRoute    = "Needs GPS to measure pace over time"
        case noHeart    = "Needs heart-rate data"
        case notSteady  = "Only steady runs — intervals decouple by design"
        case notEnough  = "Not enough data points"
    }

    struct Result {
        /// Positive = pace:HR fell away in the second half.
        let percent: Double
        let firstHalfEF: Double
        let secondHalfEF: Double

        /// The conventional coaching read. A heuristic, not a clinical threshold.
        var isCoupled: Bool { percent < 5 }

        var summary: String {
            if percent < 0 {
                return "Held together — you were stronger in the second half."
            } else if percent < 5 {
                return "Coupled. Your aerobic base supports this run."
            } else if percent < 10 {
                return "Some drift. Longer easy runs would build the base for this distance."
            }
            return "Significant drift. Heat, fuelling or an early-hard start can all cause this."
        }
    }

    /// Excludes the opening 10 minutes: a warm-up starts slow with a low heart
    /// rate, which flatters the first half and inflates the result.
    private static let warmupSeconds: TimeInterval = 600
    private static let minimumSeconds: TimeInterval = 1800   // 30 min

    static func eligibility(_ s: ActivitySession) -> Ineligible? {
        guard s.endedAt != nil else { return .notEnough }
        // Intervals and custom step workouts decouple by construction.
        if s.workoutType == .intervals || s.workoutType == .custom { return .notSteady }
        if s.activeSeconds < minimumSeconds { return .tooShort }
        if s.sortedRoute.count < 20 { return .noRoute }
        return nil
    }

    /// Splits the post-warm-up portion in half and compares speed ÷ HR either
    /// side. `samples` come from HealthKit for the session window.
    static func decoupling(_ s: ActivitySession,
                           samples: [(date: Date, bpm: Double)]) -> Result? {
        guard eligibility(s) == nil, let end = s.endedAt, !samples.isEmpty else { return nil }

        let points = s.sortedRoute
        guard let first = points.first else { return nil }
        let analysisStart = min(first.timestamp.addingTimeInterval(warmupSeconds),
                                end.addingTimeInterval(-minimumSeconds / 2))
        guard end > analysisStart else { return nil }
        let mid = analysisStart.addingTimeInterval(end.timeIntervalSince(analysisStart) / 2)

        let firstEF = halfEF(points: points, samples: samples, from: analysisStart, to: mid)
        let secondEF = halfEF(points: points, samples: samples, from: mid, to: end)
        guard let a = firstEF, let b = secondEF, a > 0 else { return nil }

        return Result(percent: (a - b) / a * 100, firstHalfEF: a, secondHalfEF: b)
    }

    /// Speed ÷ heart rate over one window, or nil when either is unmeasurable.
    private static func halfEF(points: [RoutePoint], samples: [(date: Date, bpm: Double)],
                               from: Date, to: Date) -> Double? {
        let window = points.filter { $0.timestamp >= from && $0.timestamp <= to }
        guard window.count >= 5 else { return nil }

        var meters = 0.0
        for i in 1..<window.count {
            let a = CLLocation(latitude: window[i - 1].latitude, longitude: window[i - 1].longitude)
            let b = CLLocation(latitude: window[i].latitude, longitude: window[i].longitude)
            meters += b.distance(from: a)
        }
        let seconds = to.timeIntervalSince(from)
        guard seconds > 0, meters > 0 else { return nil }

        let hr = samples.filter { $0.date >= from && $0.date <= to }.map(\.bpm)
        guard hr.count >= 3 else { return nil }
        let avgHR = hr.reduce(0, +) / Double(hr.count)
        guard avgHR > 0 else { return nil }

        return (meters / seconds) / avgHR
    }
}
