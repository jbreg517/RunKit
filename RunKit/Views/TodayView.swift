import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @AppStorage("dailyStepGoal") private var goal = 8000
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage("weeklyActiveTarget") private var weeklyTarget = 3
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    @State private var motion = MotionService.shared

    @Query(sort: \ActivitySession.startedAt, order: .reverse)
    private var sessions: [ActivitySession]
    @Query(sort: \CustomWorkout.createdAt, order: .reverse)
    private var templates: [CustomWorkout]
    @Query(sort: \ScheduledRun.date) private var scheduled: [ScheduledRun]

    @State private var showBuilder = false
    @State private var showSchedule = false
    @State private var showLibrary = false

    /// Scheduled runs due today, plus any carried forward from a missed day.
    private var dueRuns: [ScheduledRun] { scheduled.filter(\.isDue) }

    /// A rotating handful of prebuilt workouts, so the row isn't always identical.
    private var prebuiltPicks: [WorkoutRecipe] {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let all = WorkoutRecipe.all
        guard all.count > 6 else { return all }
        let start = day % all.count
        return (0..<6).map { all[(start + $0) % all.count] }
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
                    ActivityCalendarView(sessions: sessions, scheduled: scheduled)
                    dueSection
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
            .navigationTitle("Today")
            .background(RKColor.background.ignoresSafeArea())
            .onAppear { motion.startToday() }
            .sheet(isPresented: $showBuilder) {
                // Built here, a workout is saved for reuse rather than run now —
                // so this sheet saves on confirm and hides its own save control.
                WorkoutBuilderView(unit: unit, primaryTitle: "Save", offersSave: false) { built, name in
                    context.insert(CustomWorkout(name: name.isEmpty ? "Untitled" : name,
                                                 steps: built))
                }
            }
            .sheet(isPresented: $showSchedule) {
                ScheduleRunSheet(unit: unit)
            }
            .sheet(isPresented: $showLibrary) {
                WorkoutLibraryView(unit: unit) { recipe in
                    router.startRun(PendingWorkout(recipe: recipe))
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

    private func overdueLabel(_ run: ScheduledRun) -> String {
        let cal = Calendar.current
        guard !cal.isDateInToday(run.date) else { return "" }
        let days = cal.dateComponents([.day], from: run.date, to: Date()).day ?? 0
        return days == 1 ? "Yesterday · " : "\(days) days ago · "
    }

    // MARK: Your workouts (saved templates)

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack {
                sectionHeader("YOUR WORKOUTS")
                Spacer()
                Button {
                    showSchedule = true
                } label: {
                    Label("Schedule", systemImage: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(RKColor.accent)
                }
            }
            .padding(.horizontal, RKSpacing.md)

            if templates.isEmpty {
                Text("Build a workout once and it lives here — warm-up, work at a target pace, cool-down.")
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
                    .padding(.horizontal, RKSpacing.md)
            } else {
                ForEach(templates) { t in
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

            Button {
                showBuilder = true
            } label: {
                HStack(spacing: RKSpacing.sm) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(RKColor.accent)
                    Text("New workout")
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

    private func templateSummary(_ t: CustomWorkout) -> String {
        let steps = t.steps
        let count = "\(steps.count) step\(steps.count == 1 ? "" : "s")"
        guard let first = steps.first else { return count }
        return "\(count) · starts \(first.summary(unit))"
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
                                Image(systemName: r.category.sfSymbol)
                                    .foregroundColor(RKColor.accent)
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
                showLibrary = true
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
        HStack(alignment: .top, spacing: RKSpacing.md) {
            ringCard
            VStack(spacing: RKSpacing.sm) {
                stat(String(format: "%.2f", unit.distance(motion.distanceMeters)),
                     unit.distanceUnit, "map")
                stat("\(Int(estimatedKcal))", "kcal", "flame.fill")
                stat("\(motion.flights)", "flights", "stairs")
            }
        }
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
