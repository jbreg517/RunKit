import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @AppStorage("dailyStepGoal") private var goal = 8000
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage("weeklyActiveTarget") private var weeklyTarget = 3
    @AppStorage(FavoriteRecipes.key) private var favoriteRecipesRaw = ""
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    @State private var motion = MotionService.shared

    @Query(sort: \ActivitySession.startedAt, order: .reverse)
    private var sessions: [ActivitySession]
    @Query(sort: \CustomWorkout.createdAt, order: .reverse)
    private var templates: [CustomWorkout]
    @Query(sort: \ScheduledRun.date) private var scheduled: [ScheduledRun]

    /// One sheet binding rather than four stacked `.sheet` modifiers — several
    /// on a single view is a fragile SwiftUI pattern where later ones can be
    /// silently ignored.
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case builder, schedule, library, upcoming
        case day(Date)

        var id: String {
            switch self {
            case .builder:      return "builder"
            case .schedule:     return "schedule"
            case .library:      return "library"
            case .upcoming:     return "upcoming"
            case let .day(d):   return "day-\(d.timeIntervalSince1970)"
            }
        }
    }

    /// Scheduled runs due today, plus any carried forward from a missed day.
    private var dueRuns: [ScheduledRun] { scheduled.filter(\.isDue) }

    /// A rotating handful of prebuilt workouts, so the row isn't always identical.
    private var prebuiltPicks: [WorkoutRecipe] {
        let favs = FavoriteRecipes.names(favoriteRecipesRaw)
        let starred = WorkoutRecipe.all.filter { favs.contains($0.name) }
        // Favourites lead; the rest rotate daily so the row isn't static.
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let rest = WorkoutRecipe.all.filter { !favs.contains($0.name) }
        guard !rest.isEmpty else { return starred }
        let start = day % rest.count
        let rotated = (0..<min(6, rest.count)).map { rest[(start + $0) % rest.count] }
        return starred + rotated
    }

    /// Favourited templates lead the list.
    private var orderedTemplates: [CustomWorkout] {
        templates.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.createdAt > b.createdAt
        }
    }

    private var streak: StreakCalculator.Result {
        StreakCalculator.compute(dates: sessions.map(\.startedAt), weeklyTarget: weeklyTarget)
    }

    private var progress: Double {
        goal > 0 ? min(1, Double(motion.steps) / Double(goal)) : 0
    }
    private var estimatedKcal: Double { Double(motion.steps) * 0.04 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RKSpacing.lg) {
                    startRunButton
                    todayRow
                    ActivityCalendarView(sessions: sessions, scheduled: scheduled) { day in
                        sheet = .day(day)
                    }
                    dueSection
                    upcomingSection
                    templatesSection
                    prebuiltSection
                    streakCard
                    if !motion.available {
                        Text("Step tracking isn’t available on this device.")
                            .font(RKFont.caption)
                            .foregroundColor(RKColor.textMuted)
                            .padding(.horizontal, RKSpacing.md)
                    }
                }
                .padding(.vertical, RKSpacing.md)
                .readableWidth()
            }
            .navigationTitle("Run")
            .background(RKColor.background.ignoresSafeArea())
            .onAppear { motion.startToday() }
            .sheet(item: $sheet) { which in
                switch which {
                case .builder:
                    // Built here, a workout is saved for reuse rather than run
                    // now — so this saves on confirm and hides its own control.
                    WorkoutBuilderView(unit: unit, primaryTitle: "Save", offersSave: false) { built, name in
                        context.insert(CustomWorkout(name: name.isEmpty ? "Untitled" : name,
                                                     segments: built))
                    }
                case .schedule:
                    ScheduleRunSheet(unit: unit)
                case .library:
                    WorkoutLibraryView(unit: unit) { recipe in
                        router.startRun(PendingWorkout(recipe: recipe))
                    }
                case .upcoming:
                    UpcomingRunsView(unit: unit) { run in
                        router.startRun(PendingWorkout(scheduled: run))
                    }
                case let .day(date):
                    DayDetailSheet(day: date, unit: unit,
                                   sessions: sessions, scheduled: scheduled) { run in
                        router.startRun(PendingWorkout(scheduled: run))
                    }
                }
            }
        }
    }

    /// Section label, matching LiftKit's tracked small-caps headers.
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(RKFont.caption)
            .foregroundColor(RKColor.textMuted)
            .tracking(2)
    }

    // MARK: Due (today / carried forward)

    @ViewBuilder
    private var dueSection: some View {
        if !dueRuns.isEmpty {
            VStack(alignment: .leading, spacing: RKSpacing.sm) {
                sectionHeader("TODAY")
                    .padding(.horizontal, RKSpacing.md)
                ForEach(dueRuns) { run in
                    Button {
                        router.startRun(PendingWorkout(scheduled: run))
                    } label: {
                        HStack(spacing: RKSpacing.md) {
                            Image(systemName: run.type.sfSymbol)
                                .foregroundColor(RKColor.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.title)
                                    .font(RKFont.bodyBold)
                                    .foregroundColor(RKColor.textPrimary)
                                Text(overdueLabel(run) + run.summary(unit))
                                    .font(RKFont.caption)
                                    .foregroundColor(RKColor.textMuted)
                            }
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundColor(RKColor.accent)
                        }
                        .padding(RKSpacing.md)
                        .background(RKColor.surface)
                        .cornerRadius(RKRadius.large)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, RKSpacing.md)
                    // Not a List row, so swipe actions aren't available here.
                    .contextMenu {
                        Button("Skip this run", role: .destructive) { context.delete(run) }
                    }
                }
            }
        }
    }

    /// Scheduled ahead of today. Without this a run booked for tomorrow shows
    /// only as a calendar ring, which reads as "Schedule did nothing".
    @ViewBuilder
    private var upcomingSection: some View {
        let pending = scheduled.filter { !$0.isCompleted }
        let upcoming = pending
            .filter { $0.date > Calendar.current.startOfDay(for: Date()) }
            .prefix(4)
        // The header (and its way into Upcoming) shows whenever anything is
        // scheduled at all — otherwise a week where everything is due today would
        // leave no route to manage or cancel a series.
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: RKSpacing.sm) {
                HStack {
                    sectionHeader("UPCOMING")
                    Spacer()
                    Button("Manage") { sheet = .upcoming }
                        .font(RKFont.caption)
                        .foregroundColor(RKColor.accent)
                }
                .padding(.horizontal, RKSpacing.md)

                ForEach(Array(upcoming)) { run in
                    upcomingRow(run)
                }
            }
        }
    }

    private func upcomingRow(_ run: ScheduledRun) -> some View {
        Button {
            router.startRun(PendingWorkout(scheduled: run))
        } label: {
            HStack(spacing: RKSpacing.md) {
                Image(systemName: run.type.sfSymbol)
                    .foregroundColor(RKColor.textMuted)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .font(RKFont.bodyBold)
                        .foregroundColor(RKColor.textPrimary)
                    Text("\(dayLabel(run.date)) · \(run.summary(unit))")
                        .font(RKFont.caption)
                        .foregroundColor(RKColor.textMuted)
                }
                Spacer()
                if run.seriesID != nil {
                    Image(systemName: "repeat")
                        .font(RKFont.caption)
                        .foregroundColor(RKColor.textMuted)
                }
            }
            .padding(RKSpacing.md)
            .background(RKColor.surface)
            .cornerRadius(RKRadius.large)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RKSpacing.md)
        .contextMenu {
            Button("Remove", role: .destructive) { context.delete(run) }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = cal.dateComponents([.day], from: Date(), to: d).day ?? 0 < 7 ? "EEEE" : "EEE d MMM"
        return f.string(from: d)
    }

    private func overdueLabel(_ run: ScheduledRun) -> String {
        let cal = Calendar.current
        guard !cal.isDateInToday(run.date) else { return "" }
        let days = cal.dateComponents([.day], from: run.date, to: Date()).day ?? 0
        return days == 1 ? "Yesterday · " : "\(days) days ago · "
    }

    // MARK: Your workouts (saved templates)

    /// Scheduling lives behind one always-visible control, following LiftKit's
    /// "Schedule ▸ Manage Upcoming" menu. It sits on this header rather than on
    /// UPCOMING because that section hides when nothing is scheduled — which is
    /// also when a stale series most needs cancelling.
    private var scheduleMenu: some View {
        Menu {
            Button { sheet = .schedule } label: {
                Label("Schedule a Run", systemImage: "calendar.badge.plus")
            }
            Button { sheet = .upcoming } label: {
                Label("Manage Upcoming", systemImage: "calendar.badge.clock")
            }
        } label: {
            Label("Schedule", systemImage: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(RKColor.accent)
        }
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack {
                sectionHeader("YOUR WORKOUTS")
                Spacer()
                scheduleMenu
            }
            .padding(.horizontal, RKSpacing.md)

            buildCustomButton

            if templates.isEmpty {
                Text("Build a workout once and it lives here — warm-up, work at a target pace, cool-down.")
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
                    .padding(.horizontal, RKSpacing.md)
            } else {
                ForEach(orderedTemplates) { t in
                    Button {
                        router.startRun(PendingWorkout(custom: t))
                    } label: {
                        HStack(spacing: RKSpacing.md) {
                            Image(systemName: "list.bullet.indent")
                                .foregroundColor(RKColor.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name.isEmpty ? "Untitled" : t.name)
                                    .font(RKFont.bodyBold)
                                    .foregroundColor(RKColor.textPrimary)
                                Text(templateSummary(t))
                                    .font(RKFont.caption)
                                    .foregroundColor(RKColor.textMuted)
                            }
                            Spacer()
                            FavoriteStar(isOn: t.isFavorite) {
                                t.isFavorite.toggle()
                                try? context.save()
                            }
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundColor(RKColor.accent)
                        }
                        .padding(RKSpacing.md)
                        .background(RKColor.surface)
                        .cornerRadius(RKRadius.large)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, RKSpacing.md)
                }
            }
        }
    }

    private var buildCustomButton: some View {
        Button {
            sheet = .builder
        } label: {
            HStack(spacing: RKSpacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(RKColor.accent)
                Text("Build Custom")
                    .font(RKFont.bodyBold)
                    .foregroundColor(RKColor.accent)
                Spacer()
            }
            .padding(RKSpacing.md)
            .frame(maxWidth: .infinity)
            .background(RKColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: RKRadius.large)
                    .strokeBorder(RKColor.surfaceElevated, lineWidth: 1)
            )
            .cornerRadius(RKRadius.large)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RKSpacing.md)
    }

    private func templateSummary(_ t: CustomWorkout) -> String {
        let cards = t.segments
        guard let first = cards.first else { return "Empty" }
        guard cards.count > 1 else { return first.summary(unit) }
        return "\(cards.count) cards · starts \(first.summary(unit))"
    }

    // MARK: Prebuilt workouts

    private var prebuiltSection: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            sectionHeader("PREBUILT WORKOUTS")
                .padding(.horizontal, RKSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RKSpacing.md) {
                    ForEach(prebuiltPicks) { r in
                        Button {
                            router.startRun(PendingWorkout(recipe: r))
                        } label: {
                            VStack(alignment: .leading, spacing: RKSpacing.xs) {
                                HStack {
                                    Image(systemName: r.category.sfSymbol)
                                        .foregroundColor(RKColor.accent)
                                    Spacer()
                                    FavoriteStar(isOn: FavoriteRecipes.contains(r.name, in: favoriteRecipesRaw)) {
                                        favoriteRecipesRaw = FavoriteRecipes.toggle(r.name, in: favoriteRecipesRaw)
                                    }
                                }
                                Text(r.name)
                                    .font(RKFont.bodyBold)
                                    .foregroundColor(RKColor.textPrimary)
                                    .lineLimit(1)
                                Text(r.summary)
                                    .font(RKFont.caption)
                                    .foregroundColor(RKColor.textMuted)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .frame(width: 150, height: 110, alignment: .topLeading)
                            .padding(RKSpacing.md)
                            .background(RKColor.surface)
                            .cornerRadius(RKRadius.large)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, RKSpacing.md)
            }

            Button {
                sheet = .library
            } label: {
                HStack(spacing: RKSpacing.sm) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 16))
                        .foregroundColor(RKColor.accent)
                    Text("All workouts")
                        .font(RKFont.bodyBold)
                        .foregroundColor(RKColor.accent)
                    Spacer()
                }
                .padding(RKSpacing.md)
                .frame(maxWidth: .infinity)
                .background(RKColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: RKRadius.large)
                        .strokeBorder(RKColor.surfaceElevated, lineWidth: 1)
                )
                .cornerRadius(RKRadius.large)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, RKSpacing.md)
        }
    }

    /// Weekly streak. Phrasing stays neutral whether or not the week is met —
    /// no "don't break your streak!" pressure, no shaming when it resets.
    private var streakCard: some View {
        let s = streak
        return HStack(spacing: RKSpacing.md) {
            Image(systemName: s.weeks > 0 ? "flame.fill" : "flame")
                .font(.title2)
                .foregroundColor(s.weeks > 0 ? RKColor.accent : RKColor.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.weeks > 0
                     ? "\(s.weeks) week\(s.weeks == 1 ? "" : "s") in a row"
                     : "No streak yet")
                    .font(RKFont.bodyBold)
                    .foregroundColor(RKColor.textPrimary)
                Text(s.currentWeekMet
                     ? "This week’s done — rest is training too."
                     : "\(s.daysThisWeek) of \(s.target) active days this week")
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
            }
            Spacer()
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    /// Primary action. Activity is no longer a tab, so this is the way in.
    private var startRunButton: some View {
        Button {
            router.startRun()
        } label: {
            Label("Start Run", systemImage: "figure.run")
        }
        .buttonStyle(RKPrimaryButtonStyle())
        .padding(.horizontal, RKSpacing.md)
    }

    /// Step ring on the left, the three stat cards stacked on the right.
    private var todayRow: some View {
        // No .top alignment and a stretched ring: the HStack sizes to the taller
        // column and the ring card fills it, so both sides line up.
        HStack(spacing: RKSpacing.md) {
            ringCard
                .frame(maxHeight: .infinity)
            VStack(spacing: RKSpacing.sm) {
                stat(String(format: "%.2f", unit.distance(motion.distanceMeters)),
                     unit.distanceUnit, "map")
                stat("\(Int(estimatedKcal))", "kcal", "flame.fill")
                stat("\(motion.flights)", "flights", "stairs")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, RKSpacing.md)
    }

    private var ringCard: some View {
        VStack(spacing: RKSpacing.sm) {
            ZStack {
                Circle().stroke(RKColor.surfaceElevated, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(RKColor.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: progress)
                VStack(spacing: 0) {
                    Text("\(motion.steps)")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundColor(RKColor.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text("steps")
                        .font(RKFont.caption)
                        .foregroundColor(RKColor.textMuted)
                }
                .padding(.horizontal, 6)
            }
            .frame(width: 124, height: 124)

            Text("of \(goal)")
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
    }

    /// Compact stat row — sized to sit in the narrow right-hand column.
    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        HStack(spacing: RKSpacing.sm) {
            Image(systemName: icon)
                .foregroundColor(RKColor.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(RKColor.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(label)
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RKSpacing.md)
        .padding(.vertical, 12)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
    }
}
