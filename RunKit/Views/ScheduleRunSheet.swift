import SwiftUI
import SwiftData

/// Puts a workout on a day. Pick a source — one of your saved templates or a
/// prebuilt workout — then a date.
///
/// Deliberately one workout at a time: series generation belongs to the v2
/// training-plan generator, which emits these in bulk.
struct ScheduleRunSheet: View {
    let unit: UnitSystem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomWorkout.createdAt, order: .reverse) private var templates: [CustomWorkout]

    @State private var date = Date()
    @State private var activityType: ActivityType = .run
    @State private var pick: Pick = .free

    private enum Pick: Hashable {
        case free
        case template(UUID)
        case recipe(String)
    }

    private var chosen: PendingWorkout {
        switch pick {
        case .free:
            var p = PendingWorkout(type: activityType)
            p.name = "Free \(activityType.rawValue)"
            return p
        case let .template(id):
            if let t = templates.first(where: { $0.id == id }) {
                return PendingWorkout(custom: t, type: activityType)
            }
            return PendingWorkout(type: activityType)
        case let .recipe(name):
            if let r = WorkoutRecipe.all.first(where: { $0.name == name }) {
                return PendingWorkout(recipe: r, type: activityType)
            }
            return PendingWorkout(type: activityType)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Activity") {
                    Picker("Type", selection: $activityType) {
                        ForEach(ActivityType.allCases) { t in
                            Label(t.rawValue, systemImage: t.sfSymbol).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Workout") {
                    Picker("Workout", selection: $pick) {
                        Text("Free — no target").tag(Pick.free)
                        if !templates.isEmpty {
                            ForEach(templates) { t in
                                Text(t.name.isEmpty ? "Untitled" : t.name).tag(Pick.template(t.id))
                            }
                        }
                        ForEach(WorkoutRecipe.all) { r in
                            Text("\(r.name) · \(r.summary)").tag(Pick.recipe(r.name))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            .navigationTitle("Schedule a Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Schedule") {
                        context.insert(ScheduledRun(date: date, from: chosen))
                        dismiss()
                    }
                }
            }
        }
    }
}
