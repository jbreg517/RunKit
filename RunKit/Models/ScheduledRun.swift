import Foundation
import SwiftData

/// A workout handed to the session screen, from wherever it was chosen — a saved
/// template, a prebuilt recipe, a scheduled run, or History's "Do Again".
///
/// One payload keeps `ActivitySessionView` from needing a separate entry path per
/// source; it just applies whatever it's given.
struct PendingWorkout {
    var activityType: ActivityType = .run
    var workoutType: WorkoutType = .free
    var meters: Double = 0        // .distance
    var minutes: Int = 0          // .time
    var work: Int = 0             // .intervals
    var rest: Int = 0
    var reps: Int = 0
    var steps: [WorkoutStep] = [] // .custom
    var name: String = ""
    /// Set when launched from the calendar so finishing can tick it off.
    var scheduleID: UUID?

    /// Just preselect an activity type (History's "Do Again").
    init(type: ActivityType) {
        self.activityType = type
    }

    init(recipe: WorkoutRecipe, type: ActivityType = .run) {
        activityType = type
        workoutType = recipe.workoutType
        meters = recipe.meters
        minutes = recipe.minutes
        work = recipe.work
        rest = recipe.rest
        reps = recipe.reps
        name = recipe.name
    }

    init(custom: CustomWorkout, type: ActivityType = .run) {
        activityType = type
        workoutType = .custom
        steps = custom.steps
        name = custom.name
    }

    init(scheduled: ScheduledRun) {
        activityType = scheduled.type
        workoutType = scheduled.workoutType
        meters = scheduled.meters
        minutes = scheduled.minutes
        work = scheduled.work
        rest = scheduled.rest
        reps = scheduled.reps
        steps = WorkoutStep.decode(scheduled.stepsJSON)
        name = scheduled.title
        scheduleID = scheduled.id
    }
}

/// A workout placed on a day. The seed of the v2 planning calendar — once the
/// plan generator exists it emits these in bulk instead of one at a time.
@Model
final class ScheduledRun {
    var id: UUID = UUID()
    /// Day it's due (start of day).
    var date: Date = Date()
    var title: String = ""
    var typeRaw: String = ActivityType.run.rawValue
    var workoutTypeRaw: String = WorkoutType.free.rawValue
    var meters: Double = 0
    var minutes: Int = 0
    var work: Int = 0
    var rest: Int = 0
    var reps: Int = 0
    var stepsJSON: String = "[]"
    var isCompleted: Bool = false
    var completedAt: Date?

    init(date: Date, from pending: PendingWorkout) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.title = pending.name.isEmpty ? pending.workoutType.label : pending.name
        self.typeRaw = pending.activityType.rawValue
        self.workoutTypeRaw = pending.workoutType.rawValue
        self.meters = pending.meters
        self.minutes = pending.minutes
        self.work = pending.work
        self.rest = pending.rest
        self.reps = pending.reps
        self.stepsJSON = WorkoutStep.encode(pending.steps)
    }

    var type: ActivityType { ActivityType(rawValue: typeRaw) ?? .run }
    var workoutType: WorkoutType { WorkoutType(rawValue: workoutTypeRaw) ?? .free }

    /// Due today or carried forward from a missed day.
    var isDue: Bool {
        !isCompleted && date <= Calendar.current.startOfDay(for: Date())
    }

    /// "5 km" / "30 min" / "8 × 30s" — whatever describes this workout.
    func summary(_ unit: UnitSystem) -> String {
        switch workoutType {
        case .distance:
            return unit.distanceString(meters, digits: meters.truncatingRemainder(dividingBy: 1000) == 0 ? 0 : 1)
        case .time:
            return "\(minutes) min"
        case .intervals:
            return "\(reps) × \(work)s / \(rest)s"
        case .custom:
            let steps = WorkoutStep.decode(stepsJSON)
            return "\(steps.count) step\(steps.count == 1 ? "" : "s")"
        case .pace, .free:
            return workoutType.label
        }
    }
}
