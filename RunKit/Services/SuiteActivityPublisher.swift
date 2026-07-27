import Foundation
import SwiftData

/// Publishes RunKit's slice of the suite activity exchange.
///
/// `SuiteActivity.swift` is the shared wire format and is byte-identical across the
/// three apps; this file is RunKit's own and is not shared. It answers the two
/// questions HealthKit can't: **how hard was that, for this runner** and **what are
/// they planning to do**.
///
/// RunKit writes only `suiteActivityFeed.runkit` and never reads or rewrites another
/// app's key, so two apps can't clobber each other.
enum SuiteActivityPublisher {
    static let source = SuiteSource.runkit

    /// Publish current load and plans. Cheap enough to call on every foreground —
    /// it's a fetch, some arithmetic, and one `UserDefaults` write.
    @MainActor
    static func publish(from context: ModelContext, now: Date = Date()) {
        let sessions = (try? context.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let scheduled = (try? context.fetch(FetchDescriptor<ScheduledRun>())) ?? []
        publish(sessions: sessions, scheduled: scheduled, now: now)
    }

    @MainActor
    static func publish(sessions: [ActivitySession], scheduled: [ScheduledRun],
                        now: Date = Date()) {
        // Newest first: `recentPace` takes the most recent runs, and the caller's
        // fetch order isn't guaranteed.
        let completed = sessions
            .filter { $0.endedAt != nil }
            .sorted { $0.startedAt > $1.startedAt }
        let reference = referenceStrain(completed, now: now)
        let feed = SuiteActivityFeed(
            source: source,
            recentLoad: dailyLoads(completed, reference: reference, now: now),
            planned: plannedSessions(scheduled, sessions: completed, reference: reference, now: now))
        SuiteActivityStore.publish(feed)
    }

    // MARK: - Load

    /// Per-day load for days the user actually did something.
    ///
    /// **Days with no session are deliberately omitted rather than published as
    /// `.rest`.** RunKit can't know a day was a rest day — the user may have lifted.
    /// Publishing zero would tell FuelKit to cut the calorie target on a day the
    /// runner trained hard in another app. Absent means "RunKit has nothing to say".
    @MainActor
    private static func dailyLoads(_ sessions: [ActivitySession], reference: Double,
                                   now: Date) -> [SuiteDailyLoad] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let earliest = cal.date(byAdding: .day,
                                      value: -SuiteActivityFeed.historyWindow,
                                      to: today) else { return [] }

        var byDay: [Date: [ActivitySession]] = [:]
        for s in sessions where s.startedAt >= earliest {
            byDay[cal.startOfDay(for: s.startedAt), default: []].append(s)
        }

        return byDay.map { day, daySessions in
            let total = daySessions.reduce(0.0) { $0 + strain(of: $1) }
            return SuiteDailyLoad(date: day,
                                  kind: .cardio,
                                  load: min(1, total / reference),
                                  perceivedEffort: 0,   // RunKit never asks for RPE
                                  sessionCount: daySessions.count)
        }
        .sorted { $0.date < $1.date }
    }

    /// Raw, unnormalised strain for one session.
    ///
    /// With heart rate this is **Edwards' TRIMP** — minutes in each zone weighted by
    /// the zone number — which is the standard way to make an easy hour and a hard
    /// half-hour comparable, and RunKit already caches the zone split.
    ///
    /// Without a Watch there's no HR at all, so it falls back to duration times a
    /// per-activity weight chosen to land on the same scale (a steady run sits around
    /// zone 2–3, so ~2.5 a minute). Cruder, but the alternative — publishing nothing
    /// for the majority of users who have no Watch — is worse.
    @MainActor
    private static func strain(of session: ActivitySession) -> Double {
        let minutes = session.activeSeconds / 60
        guard minutes > 0 else { return 0 }

        if session.hasHeartRate {
            let zoneSeconds = session.hrZoneSeconds
            let trimp = zoneSeconds.enumerated()
                .reduce(0.0) { $0 + ($1.element / 60) * Double($1.offset + 1) }
            if trimp > 0 { return trimp }
        }

        let weight: Double
        switch session.type {
        case .walk: weight = 1.5
        case .run:  weight = 2.5
        case .ride: weight = 2.2
        }
        // Intervals and structured work sit higher than steady running of the same
        // length, which is the whole reason those sessions exist.
        let structureBump = (session.workoutType == .intervals || session.workoutType == .custom)
            ? 1.3 : 1.0
        return minutes * weight * structureBump
    }

    /// What a hard day looks like **for this runner** — the 90th percentile of their
    /// own active-day strain over the last 90 days.
    ///
    /// Normalising against the user's own norm is the point of the channel: a
    /// beginner's hardest week and a marathoner's easy week should both read as
    /// "hard for them". Falls back to a fixed reference until there's enough history
    /// for a percentile to mean anything, so a first run doesn't publish 1.0.
    @MainActor
    private static func referenceStrain(_ sessions: [ActivitySession], now: Date) -> Double {
        /// ~1 hour easy, or ~35 minutes hard. A solid session for a typical runner.
        let fallback = 150.0
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: -90, to: now) else { return fallback }

        var byDay: [Date: Double] = [:]
        for s in sessions where s.startedAt >= start {
            byDay[cal.startOfDay(for: s.startedAt), default: 0] += strain(of: s)
        }
        let values = byDay.values.filter { $0 > 0 }.sorted()
        guard values.count >= 5 else { return fallback }

        let index = Int((Double(values.count - 1) * 0.9).rounded())
        // Floored so someone who only ever walks briefly doesn't have every outing
        // read as maximal — the scale should still mean something across apps.
        return max(60, values[index])
    }

    // MARK: - Plans

    /// Upcoming scheduled runs, so FuelKit can raise carbs before a long one and
    /// LiftKit can avoid stacking legs the day before.
    @MainActor
    private static func plannedSessions(_ scheduled: [ScheduledRun],
                                        sessions: [ActivitySession],
                                        reference: Double,
                                        now: Date) -> [SuitePlannedSession] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let paceSecPerMeter = recentPace(sessions)

        return scheduled
            .filter { !$0.isCompleted && $0.date >= today }
            .map { run in
                let minutes = estimatedMinutes(run, paceSecPerMeter: paceSecPerMeter)
                return SuitePlannedSession(
                    date: run.date,
                    kind: .cardio,
                    title: run.title.isEmpty ? "Run" : run.title,
                    plannedMinutes: Int(minutes.rounded()),
                    plannedLoad: min(1, minutes * plannedWeight(run) / reference))
            }
    }

    /// How long a scheduled run will take. Time-based cards say so directly;
    /// distance-based ones are converted using the runner's own recent pace, which
    /// is a far better estimate than any constant.
    @MainActor
    private static func estimatedMinutes(_ run: ScheduledRun,
                                         paceSecPerMeter: Double) -> Double {
        let cards = run.segments
        guard !cards.isEmpty else {
            // Pre-card schedules still carry the flat fields.
            if run.minutes > 0 { return Double(run.minutes) }
            if run.meters > 0 { return run.meters * paceSecPerMeter / 60 }
            return 30
        }
        var seconds = 0.0
        for card in cards {
            if card.goal == .intervals {
                seconds += card.intervalSeconds
            } else if let end = card.endBasis {
                seconds += end == .distance ? card.endMeters * paceSecPerMeter : card.endSeconds
            } else {
                seconds += 1800   // an open card — assume a half hour
            }
        }
        return seconds / 60
    }

    @MainActor
    private static func plannedWeight(_ run: ScheduledRun) -> Double {
        let base: Double
        switch run.type {
        case .walk: base = 1.5
        case .run:  base = 2.5
        case .ride: base = 2.2
        }
        return run.workoutType == .intervals ? base * 1.3 : base
    }

    /// Seconds per metre from recent completed runs, for turning a planned distance
    /// into planned minutes. Defaults to roughly 6:00/km when there's no history.
    @MainActor
    private static func recentPace(_ sessions: [ActivitySession]) -> Double {
        let usable = sessions
            .filter { $0.distanceMeters > 400 && $0.activeSeconds > 120 }
            .prefix(20)
        guard !usable.isEmpty else { return 0.36 }
        let paces = usable.map { $0.activeSeconds / $0.distanceMeters }
        return paces.reduce(0, +) / Double(paces.count)
    }
}
