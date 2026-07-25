import Foundation

/// Aggregates and records over recorded sessions. Pure functions over an array —
/// no HealthKit, no storage — so it's cheap to call from a view and easy to test.
///
/// Everything here is Tier 1 in `docs/ANALYTICS.md`: computable from what RunKit
/// already records, without heart rate.
enum StatsCalculator {

    enum Period: String, CaseIterable, Identifiable {
        case week, month, year, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .week:  return "Week"
            case .month: return "Month"
            case .year:  return "Year"
            case .all:   return "All"
            }
        }

        /// Start of the window, or nil for all-time.
        func start(_ now: Date = Date(), _ cal: Calendar = .current) -> Date? {
            switch self {
            case .week:  return cal.dateInterval(of: .weekOfYear, for: now)?.start
            case .month: return cal.dateInterval(of: .month, for: now)?.start
            case .year:  return cal.dateInterval(of: .year, for: now)?.start
            case .all:   return nil
            }
        }
    }

    struct Totals {
        var sessions = 0
        var meters = 0.0
        var seconds = 0.0
        var energyKcal = 0.0
        var activeDays = 0

        /// Seconds per meter across the whole period, 0 when not computable.
        var averagePaceSecPerMeter: Double { meters > 0 ? seconds / meters : 0 }
    }

    static func totals(_ sessions: [ActivitySession], period: Period,
                       now: Date = Date(), calendar cal: Calendar = .current) -> Totals {
        let scoped = inPeriod(sessions, period, now: now, calendar: cal)
        var t = Totals()
        t.sessions = scoped.count
        for s in scoped {
            t.meters += s.distanceMeters
            t.seconds += s.activeSeconds
            t.energyKcal += s.activeEnergyKcal
        }
        t.activeDays = Set(scoped.map { cal.startOfDay(for: $0.startedAt) }).count
        return t
    }

    static func inPeriod(_ sessions: [ActivitySession], _ period: Period,
                         now: Date = Date(), calendar cal: Calendar = .current) -> [ActivitySession] {
        let completed = sessions.filter { $0.endedAt != nil }
        guard let start = period.start(now, cal) else { return completed }
        return completed.filter { $0.startedAt >= start }
    }

    // MARK: Weekly volume

    struct WeekBucket: Identifiable {
        let weekStart: Date
        let meters: Double
        let seconds: Double
        var id: Date { weekStart }
    }

    /// Distance per week for the last `count` weeks, oldest first. Weeks with no
    /// activity are included as zeroes so a chart doesn't silently compress gaps.
    static func weeklyVolume(_ sessions: [ActivitySession], weeks count: Int = 12,
                             now: Date = Date(), calendar cal: Calendar = .current) -> [WeekBucket] {
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var buckets: [Date: (m: Double, s: Double)] = [:]
        for s in sessions where s.endedAt != nil {
            guard let w = cal.dateInterval(of: .weekOfYear, for: s.startedAt)?.start else { continue }
            buckets[w, default: (0, 0)].m += s.distanceMeters
            buckets[w, default: (0, 0)].s += s.activeSeconds
        }
        return (0..<count).reversed().compactMap { back in
            guard let w = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeek) else { return nil }
            let v = buckets[w] ?? (0, 0)
            return WeekBucket(weekStart: w, meters: v.m, seconds: v.s)
        }
    }

    // MARK: Training load

    /// Acute:chronic workload ratio — 7-day distance ÷ average 7-day distance over
    /// the last 28. Widely used as an injury-risk proxy; **>1.5 is the commonly
    /// cited elevated-risk band**. Returns nil until there's enough history for
    /// the number to mean anything.
    struct Load {
        let ratio: Double
        let acuteMeters: Double
        let chronicWeeklyMeters: Double

        var label: String {
            switch ratio {
            case ..<0.8:  return "Backing off"
            case ..<1.3:  return "Balanced"
            case ..<1.5:  return "Ramping up"
            default:      return "Ramping fast"
            }
        }

        /// True in the band where research associates a raised injury risk.
        var isElevated: Bool { ratio >= 1.5 }
    }

    static func load(_ sessions: [ActivitySession], now: Date = Date(),
                     calendar cal: Calendar = .current) -> Load? {
        let completed = sessions.filter { $0.endedAt != nil }
        guard let oldest = completed.map(\.startedAt).min(),
              let cutoff = cal.date(byAdding: .day, value: -14, to: now),
              oldest <= cutoff else { return nil }   // need ≥14 days of history

        guard let acuteStart = cal.date(byAdding: .day, value: -7, to: now),
              let chronicStart = cal.date(byAdding: .day, value: -28, to: now) else { return nil }

        let acute = completed.filter { $0.startedAt >= acuteStart }
            .reduce(0) { $0 + $1.distanceMeters }
        let chronic = completed.filter { $0.startedAt >= chronicStart }
            .reduce(0) { $0 + $1.distanceMeters }
        let chronicWeekly = chronic / 4
        guard chronicWeekly > 0 else { return nil }
        return Load(ratio: acute / chronicWeekly,
                    acuteMeters: acute,
                    chronicWeeklyMeters: chronicWeekly)
    }

    // MARK: Records

    struct Records {
        var longestMeters: ActivitySession?
        var longestDuration: ActivitySession?
        var bestPace: ActivitySession?      // fastest average pace over ≥1 km
        var biggestWeekMeters: Double = 0
        var biggestMonthMeters: Double = 0
    }

    static func records(_ sessions: [ActivitySession],
                        calendar cal: Calendar = .current) -> Records {
        let completed = sessions.filter { $0.endedAt != nil }
        var r = Records()
        r.longestMeters = completed.max { $0.distanceMeters < $1.distanceMeters }
        r.longestDuration = completed.max { $0.activeSeconds < $1.activeSeconds }
        // Require a real distance so a 30-second sprint can't hold the pace record.
        r.bestPace = completed
            .filter { $0.distanceMeters >= 1000 && $0.activeSeconds > 0 }
            .min { ($0.activeSeconds / $0.distanceMeters) < ($1.activeSeconds / $1.distanceMeters) }

        var byWeek: [Date: Double] = [:]
        var byMonth: [Date: Double] = [:]
        for s in completed {
            if let w = cal.dateInterval(of: .weekOfYear, for: s.startedAt)?.start {
                byWeek[w, default: 0] += s.distanceMeters
            }
            if let m = cal.dateInterval(of: .month, for: s.startedAt)?.start {
                byMonth[m, default: 0] += s.distanceMeters
            }
        }
        r.biggestWeekMeters = byWeek.values.max() ?? 0
        r.biggestMonthMeters = byMonth.values.max() ?? 0
        return r
    }

    /// Average cadence in steps/min across sessions that recorded steps.
    /// Available without a Watch — `CMPedometer` already counts them.
    static func averageCadence(_ sessions: [ActivitySession]) -> Double? {
        let usable = sessions.filter { $0.endedAt != nil && $0.steps > 0 && $0.activeSeconds > 60 }
        guard !usable.isEmpty else { return nil }
        let perMinute = usable.map { Double($0.steps) / ($0.activeSeconds / 60) }
        return perMinute.reduce(0, +) / Double(perMinute.count)
    }
}
