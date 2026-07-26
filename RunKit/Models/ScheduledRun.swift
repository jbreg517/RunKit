import Foundation
import SwiftData

/// A workout handed to the session screen, from wherever it was chosen — a saved
/// template, a prebuilt recipe, a scheduled run, or History's "Do Again".
///
/// One payload keeps `ActivitySessionView` from needing a separate entry path per
/// source; it just applies whatever it's given.
///
/// `segments` is the real content. The flat fields below it are the older shape,
/// still produced by `WorkoutRecipe` and by anything scheduled before v0.45;
/// `resolvedSegments` turns those into cards so the session engine only ever sees
/// one representation.
struct PendingWorkout {
    var activityType: ActivityType = .run
    var segments: [ActivitySegment] = []
    var name: String = ""
    /// Set when launched from the calendar so finishing can tick it off.
    var scheduleID: UUID?

    // Legacy flat parameters.
    var workoutType: WorkoutType = .free
    var meters: Double = 0
    var minutes: Int = 0
    var work: Int = 0
    var rest: Int = 0
    var reps: Int = 0

    /// The cards to run: what was stored, else the flat params converted.
    var resolvedSegments: [ActivitySegment] {
        if !segments.isEmpty { return segments }
        let built = ActivitySegment.fromLegacy(type: workoutType, activity: activityType,
                                               meters: meters, minutes: minutes,
                                               work: work, rest: rest, reps: reps,
                                               paceSecPerMeter: 0)
        return built.isEmpty ? ActivitySegment.starter : built
    }

    /// Just preselect an activity type (History's "Do Again").
    init(type: ActivityType) {
        self.activityType = type
        self.segments = [ActivitySegment(activity: type, goal: .none)]
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
        segments = ActivitySegment.from(recipe: recipe, activity: type)
    }

    init(custom: CustomWorkout, type: ActivityType = .run) {
        activityType = type
        segments = custom.segments
        workoutType = ActivitySegment.workoutType(for: segments)
        name = custom.name
    }

    init(segments: [ActivitySegment], name: String = "") {
        self.segments = segments
        self.activityType = segments.first?.activity ?? .run
        self.workoutType = ActivitySegment.workoutType(for: segments)
        self.name = name
    }

    init(scheduled: ScheduledRun) {
        activityType = scheduled.type
        workoutType = scheduled.workoutType
        meters = scheduled.meters
        minutes = scheduled.minutes
        work = scheduled.work
        rest = scheduled.rest
        reps = scheduled.reps
        segments = ActivitySegment.decode(scheduled.stepsJSON)
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
    /// The `ActivitySegment` cards, JSON-encoded. Attribute name predates the
    /// cards and is kept so existing stores migrate untouched.
    var stepsJSON: String = "[]"
    var isCompleted: Bool = false
    var completedAt: Date?

    init(date: Date, from pending: PendingWorkout) {
        let segments = pending.resolvedSegments
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.typeRaw = pending.activityType.rawValue
        self.workoutTypeRaw = ActivitySegment.workoutType(for: segments).rawValue
        self.meters = pending.meters
        self.minutes = pending.minutes
        self.work = pending.work
        self.rest = pending.rest
        self.reps = pending.reps
        self.stepsJSON = ActivitySegment.encode(segments)
        self.title = pending.name.isEmpty
            ? ActivitySegment.workoutType(for: segments).label
            : pending.name
    }

    var type: ActivityType { ActivityType(rawValue: typeRaw) ?? .run }
    var workoutType: WorkoutType { WorkoutType(rawValue: workoutTypeRaw) ?? .free }
    var segments: [ActivitySegment] { ActivitySegment.decode(stepsJSON) }

    /// Due today or carried forward from a missed day.
    var isDue: Bool {
        !isCompleted && date <= Calendar.current.startOfDay(for: Date())
    }

    /// "5 km" / "30 min" / "8 × 30s" — whatever describes this workout. Multi-card
    /// workouts lead with the card count so the row stays one line.
    func summary(_ unit: UnitSystem) -> String {
        let cards = segments
        if cards.count > 1 {
            return "\(cards.count) cards · starts \(cards[0].summary(unit))"
        }
        if let only = cards.first { return only.summary(unit) }
        return workoutType.label
    }
}
