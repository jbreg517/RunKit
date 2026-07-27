import SwiftUI
import SwiftData

/// Puts a workout on a day — or on a repeating set of days.
///
/// Recurrence follows LiftKit: pick the weekdays, pick an end date, and the series
/// is **expanded into real `ScheduledRun` rows immediately**, all sharing a
/// `seriesID`. No rule to evaluate later, every occurrence individually editable,
/// and the whole series still cancellable as a unit from Upcoming.
///
/// Where it deliberately differs from LiftKit: LiftKit rotates up to five plans
/// across the chosen days (A, B, A, B…), which suits push/pull/legs. Running weeks
/// aren't rotations — the long run belongs on Sunday every week — so instead of a
/// rotation this offers **a workout per weekday**. Leaving that off applies the one
/// chosen workout to every day, which is LiftKit's simple recurring case.
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

    // Recurrence
    @State private var weekdays: Set<Int> = []
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var varyByDay = false
    @State private var perDay: [Int: Pick] = [:]

    private let cal = Calendar.current
    private let weekdayLabels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
    /// Safety valve. An end date years out would otherwise insert thousands of
    /// rows in one tap; the summary says when the range has been clipped.
    private let maxOccurrences = 200

    private enum Pick: Hashable {
        case free
        case template(UUID)
        case recipe(String)
    }

    private var isRecurring: Bool { !weekdays.isEmpty }

    // MARK: Workout sources

    private var orderedTemplates: [CustomWorkout] {
        templates.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.createdAt > b.createdAt
        }
    }

    private var orderedRecipes: [WorkoutRecipe] {
        FavoriteRecipes.sorted(WorkoutRecipe.all, raw: favoriteRecipesRaw)
    }

    private func pending(for pick: Pick) -> PendingWorkout {
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

    private func label(for pick: Pick) -> String {
        switch pick {
        case .free:
            return "Free \(activityType.rawValue)"
        case let .template(id):
            let t = templates.first { $0.id == id }
            return t.map { $0.name.isEmpty ? "Untitled" : $0.name } ?? "Workout"
        case let .recipe(name):
            return name
        }
    }

    // MARK: Occurrences

    /// Every run this sheet would create. One entry for a one-off; the expanded
    /// weekday series otherwise.
    private var occurrences: [(date: Date, pick: Pick)] {
        guard isRecurring else { return [(cal.startOfDay(for: date), pick)] }
        var out: [(date: Date, pick: Pick)] = []
        var current = cal.startOfDay(for: date)
        let end = cal.startOfDay(for: endDate)
        while current <= end, out.count < maxOccurrences {
            let wd = cal.component(.weekday, from: current)
            if weekdays.contains(wd) {
                out.append((current, varyByDay ? (perDay[wd] ?? pick) : pick))
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return out
    }

    private var summaryText: String {
        guard isRecurring else { return "One run on \(longDate(date))." }
        let n = occurrences.count
        guard n > 0 else { return "No days in this range fall on the weekdays you picked." }
        let days = weekdays.sorted().map { weekdayLabels[$0 - 1] }.joined(separator: "/")
        let clipped = n >= maxOccurrences ? " (capped — shorten the range for more)" : ""
        return "\(n) run\(n == 1 ? "" : "s") · \(days) · ends \(longDate(occurrences.last?.date ?? endDate))\(clipped)"
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                whenSection
                activitySection
                workoutSection
                repeatSection
                if isRecurring { rangeSection }
                if isRecurring && weekdays.count > 1 { varySection }
                Section { Text(summaryText).font(RKFont.caption).foregroundColor(RKColor.textMuted) }
            }
            .navigationTitle(isRecurring ? "Schedule a Series" : "Schedule a Run")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                date = initialDate
                if endDate <= initialDate {
                    endDate = cal.date(byAdding: .month, value: 1, to: initialDate) ?? initialDate
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Schedule") { schedule() }
                        .disabled(occurrences.isEmpty)
                }
            }
        }
    }

    private var whenSection: some View {
        Section(isRecurring ? "Starting" : "When") {
            DatePicker("Date", selection: $date, displayedComponents: .date)
        }
    }

    private var activitySection: some View {
        Section("Activity") {
            Picker("Type", selection: $activityType) {
                ForEach(ActivityType.allCases) { t in
                    Label(t.rawValue, systemImage: t.sfSymbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var workoutSection: some View {
        Section {
            workoutPicker("Workout", selection: $pick)
        } header: {
            Text(varyByDay && isRecurring ? "Default workout" : "Workout")
        }
    }

    /// Favourites lead so the common choice is first.
    private func workoutPicker(_ title: String, selection: Binding<Pick>) -> some View {
        Picker(title, selection: selection) {
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

    private var repeatSection: some View {
        Section {
            HStack(spacing: RKSpacing.xs) {
                ForEach(1...7, id: \.self) { wd in
                    weekdayChip(wd)
                }
            }
        } header: {
            Text("Repeat on")
        } footer: {
            Text(isRecurring
                 ? "Tap days off to go back to a single run."
                 : "Pick days to repeat weekly. Leave them all off for a one-off run.")
        }
    }

    private func weekdayChip(_ wd: Int) -> some View {
        let on = weekdays.contains(wd)
        return Button {
            if on { weekdays.remove(wd) } else { weekdays.insert(wd) }
        } label: {
            Text(weekdayLabels[wd - 1])
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, RKSpacing.sm)
                .background(on ? RKColor.accent : RKColor.surfaceElevated)
                .foregroundColor(on ? RKColor.onAccent : RKColor.textSecondary)
                .cornerRadius(RKRadius.small)
        }
        .buttonStyle(.plain)
    }

    private var rangeSection: some View {
        Section("Until") {
            DatePicker("End", selection: $endDate, in: date..., displayedComponents: .date)
        }
    }

    /// A workout per weekday — the running-specific bit. Tuesday intervals and a
    /// Sunday long run stay on their own days, which a rotation can't express.
    private var varySection: some View {
        Section {
            Toggle("Different workout per day", isOn: $varyByDay)
                .tint(RKColor.accent)
            if varyByDay {
                ForEach(weekdays.sorted(), id: \.self) { wd in
                    workoutPicker(fullWeekday(wd), selection: Binding(
                        get: { perDay[wd] ?? pick },
                        set: { perDay[wd] = $0 }))
                }
            }
        } footer: {
            if varyByDay {
                Text("Days you don't set use the default workout above.")
            }
        }
    }

    // MARK: Commit

    private func schedule() {
        let runs = occurrences
        guard !runs.isEmpty else { return }
        // Only a real series gets an ID; a lone run stays a one-off so Upcoming
        // doesn't show a "series" of one.
        let series: UUID? = runs.count > 1 ? UUID() : nil
        for run in runs {
            context.insert(ScheduledRun(date: run.date, from: pending(for: run.pick),
                                        seriesID: series))
        }
        // Explicit save: without it the inserts may not be visible to other views'
        // @Query before the sheet dismisses.
        Persist.save(context)
        // New plans are exactly what the other apps want early warning of.
        SuiteActivityPublisher.publish(from: context)
        dismiss()
    }

    // MARK: Formatting

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private func longDate(_ d: Date) -> String { Self.dayFormatter.string(from: d) }

    /// Localised weekday name for the per-day pickers, so they don't read as "Mo".
    private func fullWeekday(_ wd: Int) -> String {
        let names = cal.weekdaySymbols
        return wd - 1 < names.count ? names[wd - 1] : weekdayLabels[wd - 1]
    }
}
