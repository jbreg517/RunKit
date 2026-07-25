import SwiftUI
import SwiftData

/// Replaces the old History tab: totals, trends and records, with the session
/// list as one segment rather than the whole tab.
///
/// Named `StatsView`, not `ProgressView` — SwiftUI already defines a
/// `ProgressView`, and a same-named type in this module would shadow it and
/// break existing uses (`SettingsView`'s export spinner).
///
/// Every section is its own small property: an inlined body of this size hits
/// "the compiler is unable to type-check this expression in reasonable time",
/// which is a hard build error (it bit SettingsView in v0.37).
struct StatsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    @Query(sort: \ActivitySession.startedAt, order: .reverse) private var sessions: [ActivitySession]

    @State private var tab: Segment = .summary
    @State private var period: StatsCalculator.Period = .month

    private enum Segment: String, CaseIterable, Identifiable {
        case summary, records, sessions
        var id: String { rawValue }
        var label: String {
            switch self {
            case .summary:  return "Summary"
            case .records:  return "Records"
            case .sessions: return "Sessions"
            }
        }
    }

    private var completed: [ActivitySession] { sessions.filter { $0.endedAt != nil } }

    var body: some View {
        NavigationStack {
            Group {
                if completed.isEmpty {
                    ContentUnavailableView(
                        "Nothing to show yet",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Record a walk, run or ride and your stats build up here.")
                    )
                } else {
                    content
                }
            }
            .navigationTitle("Stats")
            .background(RKColor.background.ignoresSafeArea())
            .navigationDestination(for: ActivitySession.self) { SessionDetailView(session: $0) }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Segment.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, RKSpacing.md)
            .padding(.bottom, RKSpacing.sm)

            switch tab {
            case .summary:  summary
            case .records:  records
            case .sessions: sessionList
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        ScrollView {
            VStack(spacing: RKSpacing.lg) {
                periodPicker
                heroTiles
                weeklyVolumeCard
                loadCard
                cadenceCard
                heartRateCard
            }
            .padding(.vertical, RKSpacing.md)
            .readableWidth()
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(StatsCalculator.Period.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, RKSpacing.md)
    }

    private var heroTiles: some View {
        let t = StatsCalculator.totals(sessions, period: period)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: RKSpacing.md),
                                   GridItem(.flexible(), spacing: RKSpacing.md)],
                         spacing: RKSpacing.md) {
            tile("Distance", unit.distanceString(t.meters), "map")
            tile("Time", durationString(t.seconds), "clock")
            tile("Sessions", "\(t.sessions)", "figure.run")
            tile("Active days", "\(t.activeDays)", "calendar")
        }
        .padding(.horizontal, RKSpacing.md)
    }

    private func tile(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: RKSpacing.xs) {
            Image(systemName: icon).foregroundColor(RKColor.accent)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(RKColor.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
    }

    /// Hand-rolled bars rather than Swift Charts — trivial to render, no extra
    /// type-checking cost, and the shape is all this needs to convey.
    private var weeklyVolumeCard: some View {
        let weeks = StatsCalculator.weeklyVolume(sessions, weeks: 12)
        let peak = weeks.map(\.meters).max() ?? 0
        return VStack(alignment: .leading, spacing: RKSpacing.sm) {
            Text("Weekly distance").font(RKFont.heading).foregroundColor(RKColor.textPrimary)
            if peak <= 0 {
                Text("No distance recorded in the last 12 weeks.")
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(weeks) { w in
                        VStack(spacing: 3) {
                            Capsule()
                                .fill(w.meters > 0 ? RKColor.accent : RKColor.surfaceElevated)
                                .frame(height: max(3, 90 * (w.meters / peak)))
                            Text(weekLabel(w.weekStart))
                                .font(.system(size: 9))
                                .foregroundColor(RKColor.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 110, alignment: .bottom)
                Text("Peak \(unit.distanceString(peak)) · last 12 weeks")
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
            }
        }
        .padding(RKSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    @ViewBuilder
    private var loadCard: some View {
        if let load = StatsCalculator.load(sessions) {
            VStack(alignment: .leading, spacing: RKSpacing.xs) {
                HStack {
                    Text("Training load").font(RKFont.heading).foregroundColor(RKColor.textPrimary)
                    Spacer()
                    Text(String(format: "%.2f", load.ratio))
                        .font(RKFont.bodyBold)
                        .foregroundColor(load.isElevated ? RKColor.danger : RKColor.accent)
                }
                Text(load.label)
                    .font(RKFont.bodyBold)
                    .foregroundColor(load.isElevated ? RKColor.danger : RKColor.textSecondary)
                Text("This week \(unit.distanceString(load.acuteMeters)) against a \(unit.distanceString(load.chronicWeeklyMeters)) average. Ratios above 1.5 are linked to higher injury risk — an estimate, not a diagnosis.")
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(RKSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RKColor.surface)
            .cornerRadius(RKRadius.large)
            .padding(.horizontal, RKSpacing.md)
        }
    }

    @ViewBuilder
    private var cadenceCard: some View {
        if let cadence = StatsCalculator.averageCadence(sessions) {
            statRow("Average cadence", String(format: "%.0f spm", cadence),
                    "Steps per minute across your recorded sessions.", "metronome")
        }
    }

    /// Empty until heart-rate samples exist. HR does **not** need a Watch app —
    /// HealthKit exposes samples from any source; see `docs/ANALYTICS.md`.
    private var heartRateCard: some View {
        statRow("Heart rate", "—",
                "Zones, training distribution and aerobic drift appear here once heart-rate data is available from Apple Health.",
                "heart.fill")
    }

    private func statRow(_ title: String, _ value: String, _ note: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: RKSpacing.xs) {
            HStack {
                Label(title, systemImage: icon)
                    .font(RKFont.heading)
                    .foregroundColor(RKColor.textPrimary)
                Spacer()
                Text(value).font(RKFont.bodyBold).foregroundColor(RKColor.accent)
            }
            Text(note)
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RKSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    // MARK: Records

    private var records: some View {
        let r = StatsCalculator.records(sessions)
        return ScrollView {
            VStack(spacing: RKSpacing.md) {
                recordRow("Longest distance", r.longestMeters.map { unit.distanceString($0.distanceMeters) },
                          r.longestMeters?.startedAt, "arrow.left.and.right")
                recordRow("Longest duration", r.longestDuration.map { durationString($0.activeSeconds) },
                          r.longestDuration?.startedAt, "clock")
                recordRow("Best average pace",
                          r.bestPace.map { unit.paceString(seconds: $0.activeSeconds, meters: $0.distanceMeters) },
                          r.bestPace?.startedAt, "speedometer")
                recordRow("Biggest week", r.biggestWeekMeters > 0 ? unit.distanceString(r.biggestWeekMeters) : nil,
                          nil, "calendar")
                recordRow("Biggest month", r.biggestMonthMeters > 0 ? unit.distanceString(r.biggestMonthMeters) : nil,
                          nil, "calendar.badge.clock")

                Text("Split records (fastest 1 K, 5 K, 10 K) arrive with the charts update.")
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
                    .padding(.horizontal, RKSpacing.md)
            }
            .padding(.vertical, RKSpacing.md)
            .readableWidth()
        }
    }

    private func recordRow(_ title: String, _ value: String?, _ date: Date?, _ icon: String) -> some View {
        HStack(spacing: RKSpacing.md) {
            Image(systemName: icon).foregroundColor(RKColor.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(RKFont.bodyBold).foregroundColor(RKColor.textPrimary)
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(RKFont.caption).foregroundColor(RKColor.textMuted)
                }
            }
            Spacer()
            Text(value ?? "—")
                .font(RKFont.bodyBold)
                .foregroundColor(value == nil ? RKColor.textMuted : RKColor.accent)
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    // MARK: Sessions

    private var sessionList: some View {
        List {
            ForEach(completed) { s in
                NavigationLink(value: s) { row(s) }
            }
            .onDelete(perform: delete)
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ s: ActivitySession) -> some View {
        HStack(spacing: RKSpacing.md) {
            Image(systemName: s.type.sfSymbol)
                .foregroundColor(RKColor.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.type.rawValue)
                    .font(RKFont.bodyBold)
                    .foregroundColor(RKColor.textPrimary)
                Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if s.distanceMeters > 0 {
                    Text((s.distanceEstimated ? "~" : "") + unit.distanceString(s.distanceMeters))
                        .font(RKFont.bodyBold)
                        .foregroundColor(RKColor.textPrimary)
                }
                Text(durationString(s.activeSeconds))
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textSecondary)
            }
        }
        .listRowBackground(RKColor.surface)
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(completed[i]) }
        try? context.save()
    }

    // MARK: Helpers

    private func durationString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m \(s)s"
    }

    private func weekLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d/M"
        return f.string(from: d)
    }
}
