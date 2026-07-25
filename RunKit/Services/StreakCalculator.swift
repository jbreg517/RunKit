import Foundation

/// Streaks that survive rest days.
///
/// Conventional streaks punish the single most important training behaviour —
/// resting — and turn into a guilt engine the day you miss. RunKit's version is
/// **weekly**, not daily: a streak counts consecutive weeks in which you were
/// active at least `weeklyTarget` days. Rest days cost nothing, and one quiet
/// week ends a streak without any shaming copy.
///
/// Deliberately absent: "don't lose your streak!" nudges, freezes to buy back,
/// and anything that pressures training through injury.
enum StreakCalculator {

    struct Result {
        /// Consecutive qualifying weeks ending with the current or previous week.
        let weeks: Int
        /// Active days inside the current (possibly incomplete) week.
        let daysThisWeek: Int
        /// Days needed per week to qualify.
        let target: Int
        /// True once the current week already qualifies.
        var currentWeekMet: Bool { daysThisWeek >= target }
    }

    /// - Parameters:
    ///   - dates: start dates of recorded sessions (any order).
    ///   - weeklyTarget: qualifying active days per week.
    ///   - calendar: injected so tests can pin the first weekday.
    static func compute(dates: [Date], weeklyTarget: Int = 3,
                        now: Date = Date(), calendar: Calendar = .current) -> Result {
        let target = max(1, weeklyTarget)

        // Collapse to distinct active days, then group by the week they fall in.
        let activeDays = Set(dates.map { calendar.startOfDay(for: $0) })
        var perWeek: [Date: Int] = [:]
        for day in activeDays {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { continue }
            perWeek[week, default: 0] += 1
        }

        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return Result(weeks: 0, daysThisWeek: 0, target: target)
        }
        let daysThisWeek = perWeek[thisWeek] ?? 0

        // Walk backwards. The current week is counted only once it qualifies, but
        // an unfinished week that hasn't qualified *yet* must not break a streak
        // built on previous weeks — so start from last week in that case.
        var streak = 0
        var cursor = daysThisWeek >= target
            ? thisWeek
            : calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek

        while (perWeek[cursor] ?? 0) >= target {
            streak += 1
            guard let prev = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = prev
        }

        return Result(weeks: streak, daysThisWeek: daysThisWeek, target: target)
    }
}
