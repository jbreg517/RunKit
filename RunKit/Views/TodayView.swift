import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(AppRouter.self) private var router
    @AppStorage("dailyStepGoal") private var goal = 8000
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage("weeklyActiveTarget") private var weeklyTarget = 3
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    @State private var motion = MotionService.shared

    @Query(sort: \ActivitySession.startedAt, order: .reverse)
    private var sessions: [ActivitySession]

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
                    ActivityCalendarView(sessions: sessions)
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
