import SwiftUI
import SwiftData

/// Puts a workout on a day. Pick a source — one of your saved templates or a
/// prebuilt workout — then a date.
///
/// Deliberately one workout at a time: series generation belongs to the v2
/// training-plan generator, which emits these in bulk.
struct ScheduleRunSheet: View {
    let unit: UnitSystem
    /// Preselected day when opened from a calendar cell.
    var initialDate: Date = Date()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomWorkout.createdAt, order: .reverse) private var templates: [CustomWorkout]
    @AppStorage(FavoriteRecipes.key) private var favoriteRecipesRaw = ""

    @State private var date = Date()
    @State private var activityType: ActivityType = .run
    @State private var pick: Pick = .free

    private enum Pick: Hashable {
        case free
        case template(UUID)
        case recipe(String)
    }

    private var orderedTemplates: [CustomWorkout] {
        templates.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.createdAt > b.createdAt
        }
    }

    private var orderedRecipes: [WorkoutRecipe] {
        FavoriteRecipes.sorted(WorkoutRecipe.all, raw: favoriteRecipesRaw)
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
                    // Favourites lead so the common choice is first.
                    Picker("Workout", selection: $pick) {
                        Text("Free — no target").tag(Pick.free)
                        ForEach(orderedTemplates) { t in
                            Text((t.isFavorite ? "★ " : "") + (t.name.isEmpty ? "Untitled" : t.name))
                                .tag(Pick.template(t.id))
                        }
                        ForEach(orderedRecipes) { r in
                            let star = FavoriteRecipes.contains(r.name, in: favoriteRecipesRaw) ? "★ " : ""
                            Text("\(star)\(r.name) · \(r.summary)").tag(Pick.recipe(r.name))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            .navigationTitle("Schedule a Run")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { date = initialDate }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Schedule") {
                        context.insert(ScheduledRun(date: date, from: chosen))
                        // Explicit save: without it the insert may not be visible
                        // to other views' @Query before the sheet dismisses.
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
