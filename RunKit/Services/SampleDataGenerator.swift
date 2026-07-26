import Foundation
import SwiftData

/// Generates a plausible training history so the screens can be reviewed before
/// real data exists.
///
/// ⚠️ **Development only — remove before App Store submission.** It's reachable
/// from Settings ▸ Developer so it works in a TestFlight (release) build, which
/// `#if DEBUG` would not.
///
/// Models an intermediate runner: 4–5 runs a week, 20–30 miles, a long run, one
/// tempo and one interval session, with a lighter every fourth week. Heart rate
/// is written straight into the cached fields — RunKit only *reads* HR from
/// HealthKit, so there's nowhere else to put it.
enum SampleDataGenerator {

    /// Rough loop around a base point; enough for thumbnails, splits and the
    /// decoupling split-halves maths.
    private static let baseLat = 51.5074
    private static let baseLon = -0.1278

    struct Plan {
        let dayOffset: Int          // days before today
        let meters: Double
        let paceSecPerKm: Double
        let kind: Kind

        enum Kind { case easy, long, tempo, intervals }
    }

    /// 13 weeks of sessions, newest last.
    static func plan(weeks: Int = 13) -> [Plan] {
        var out: [Plan] = []
        for week in 0..<weeks {
            // Build volume, with every 4th week a cutback.
            let base = 34_000.0 + Double(weeks - week) * 700          // metres/week
            let isDown = (weeks - week) % 4 == 0
            let weekly = (isDown ? base * 0.72 : base)
            let daysBack = (weeks - week - 1) * 7

            // Long run ~32% of the week, then tempo, intervals and easy runs.
            let long = weekly * 0.32
            let tempo = weekly * 0.18
            let intervals = weekly * 0.15
            let easyEach = (weekly - long - tempo - intervals) / 2

            out.append(Plan(dayOffset: daysBack + 6, meters: easyEach, paceSecPerKm: 372, kind: .easy))
            out.append(Plan(dayOffset: daysBack + 5, meters: intervals, paceSecPerKm: 318, kind: .intervals))
            out.append(Plan(dayOffset: daysBack + 3, meters: easyEach, paceSecPerKm: 378, kind: .easy))
            out.append(Plan(dayOffset: daysBack + 2, meters: tempo, paceSecPerKm: 330, kind: .tempo))
            out.append(Plan(dayOffset: daysBack, meters: long, paceSecPerKm: 390, kind: .long))
        }
        return out
    }

    @MainActor
    static func generate(into context: ModelContext, weeks: Int = 13) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        for p in plan(weeks: weeks) {
            guard let day = cal.date(byAdding: .day, value: -p.dayOffset, to: today) else { continue }
            // Land runs in the morning, varying a little so they aren't identical.
            let start = cal.date(bySettingHour: 7, minute: (p.dayOffset * 7) % 45, second: 0, of: day) ?? day
            let seconds = (p.meters / 1000) * p.paceSecPerKm
            let end = start.addingTimeInterval(seconds)

            let s = ActivitySession(type: .run)
            s.startedAt = start
            s.endedAt = end
            s.activeSeconds = seconds
            s.distanceMeters = p.meters
            s.usedGPS = true
            s.steps = Int(p.meters / 1.15)                    // ~1.15 m stride
            s.activeEnergyKcal = p.meters / 1000 * 62
            s.workoutTypeRaw = (p.kind == .intervals ? WorkoutType.intervals : .free).rawValue

            applyHeartRate(to: s, kind: p.kind, seconds: seconds)
            addRoute(to: s, start: start, seconds: seconds, meters: p.meters, context: context)
            context.insert(s)
        }

        addUpcoming(into: context, from: today, calendar: cal)
        try? context.save()
    }

    // MARK: Heart rate

    private static func applyHeartRate(to s: ActivitySession, kind: Plan.Kind, seconds: Double) {
        let avg: Double, max: Double, split: [Double]
        switch kind {
        case .easy:      avg = 139; max = 152; split = [0.25, 0.55, 0.18, 0.02, 0]
        case .long:      avg = 145; max = 161; split = [0.14, 0.56, 0.26, 0.04, 0]
        case .tempo:     avg = 163; max = 178; split = [0.06, 0.18, 0.34, 0.36, 0.06]
        case .intervals: avg = 158; max = 184; split = [0.10, 0.22, 0.20, 0.28, 0.20]
        }
        s.avgHeartRateBpm = avg
        s.maxHeartRateBpm = max
        s.hrZoneSecondsJSON = HeartRateZones.encode(split.map { $0 * seconds })
        s.hrCheckedAt = Date()

        // Decoupling only applies to steady runs of 30 minutes or more, matching
        // AerobicAnalysis's own gating so the sample data stays self-consistent.
        if kind == .intervals {
            s.hasDecoupling = false
            s.decouplingNote = AerobicAnalysis.Ineligible.notSteady.rawValue
        } else if seconds < 1800 {
            s.hasDecoupling = false
            s.decouplingNote = AerobicAnalysis.Ineligible.tooShort.rawValue
        } else {
            // Long runs drift more; everything improves slightly over the block.
            let drift = kind == .long ? Double.random(in: 3.5...8.5) : Double.random(in: 1.0...5.5)
            s.hasDecoupling = true
            s.decouplingPercent = drift
            s.decouplingNote = drift < 5
                ? "Coupled. Your aerobic base supports this run."
                : "Some drift. Longer easy runs would build the base for this distance."
        }
    }

    // MARK: Route

    /// A rough loop, sampled every 15 s — plenty for the thumbnail, splits, and
    /// the ≥5-points-per-half the decoupling maths needs.
    private static func addRoute(to s: ActivitySession, start: Date, seconds: Double,
                                 meters: Double, context: ModelContext) {
        let step = 15.0
        let count = Swift.max(8, Int(seconds / step))
        let radius = (meters / 1000) * 0.0016            // scales the loop with distance
        let jitter = Double.random(in: -0.004...0.004)   // vary where runs happen

        for i in 0...count {
            let t = Double(i) / Double(count)
            let angle = t * 2 * .pi
            // Slight second harmonic so loops aren't perfect circles.
            let r = radius * (1 + 0.22 * sin(angle * 3))
            let p = RoutePoint(
                timestamp: start.addingTimeInterval(t * seconds),
                latitude: baseLat + jitter + r * sin(angle),
                longitude: baseLon + jitter + r * cos(angle) * 1.6,
                altitude: 20 + 12 * sin(angle * 2),
                horizontalAccuracy: 5,
                speed: meters / seconds,
                isEstimated: false)
            p.session = s
            context.insert(p)
        }
    }

    // MARK: Scheduled runs

    private static func addUpcoming(into context: ModelContext, from today: Date, calendar cal: Calendar) {
        let upcoming: [(Int, String, WorkoutType, Double, Int)] = [
            (1, "Easy 5K",   .distance, 5000, 0),
            (3, "Tempo 20",  .time,     0,    20),
            (5, "Long Run",  .time,     0,    60),
        ]
        for (offset, title, type, meters, minutes) in upcoming {
            guard let d = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            var p = PendingWorkout(type: .run)
            p.name = title
            p.workoutType = type
            p.meters = meters
            p.minutes = minutes
            context.insert(ScheduledRun(date: d, from: p))
        }
    }
}
