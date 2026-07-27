import SwiftUI
import SwiftData

/// Everything still ahead, in one manageable list.
///
/// Ported from LiftKit's Upcoming screen: recurring series (sharing a `seriesID`)
/// collapse into one expandable row that can be cancelled as a unit, one-offs are
/// listed individually, and there's a clear-all for when a plan has gone stale.
/// Cancelling only ever touches *upcoming* runs — anything already completed is
/// history and stays put.
struct UpcomingRunsView: View {
    let unit: UnitSystem
    /// Tapping a run starts it, matching every other list in the app.
    let onStart: (ScheduledRun) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \ScheduledRun.date) private var allRuns: [ScheduledRun]

    @State private var seriesToCancel: SeriesGroup?
    @State private var showClearAllConfirm = false

    private let cal = Calendar.current
    private let weekdayLabels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    private struct SeriesGroup: Identifiable {
        let id: UUID
        let runs: [ScheduledRun]
    }

    // MARK: Derived

    /// Includes anything still uncompleted from earlier days — a missed run is
    /// still something you have to deal with, so hiding it would be unhelpful.
    private var upcoming: [ScheduledRun] {
        allRuns.filter { !$0.isCompleted }
    }

    private var seriesGroups: [SeriesGroup] {
        Dictionary(grouping: upcoming.filter { $0.seriesID != nil }) { $0.seriesID! }
            .map { SeriesGroup(id: $0.key, runs: $0.value.sorted { $0.date < $1.date }) }
            .sorted { ($0.runs.first?.date ?? .distantFuture) < ($1.runs.first?.date ?? .distantFuture) }
    }

    private var oneOffs: [ScheduledRun] {
        upcoming.filter { $0.seriesID == nil }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if upcoming.isEmpty { emptyState } else { list }
            }
            .background(RKColor.background.ignoresSafeArea())
            .navigationTitle("Upcoming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Cancel this series?",
                                isPresented: cancelDialogBinding,
                                presenting: seriesToCancel) { group in
                Button("Cancel \(group.runs.count) Upcoming", role: .destructive) {
                    cancelSeries(group)
                    seriesToCancel = nil
                }
                Button("Keep", role: .cancel) { seriesToCancel = nil }
            } message: { group in
                Text("Removes the \(group.runs.count) run\(group.runs.count == 1 ? "" : "s") left in this series. Runs you've already finished are kept.")
            }
            .confirmationDialog("Clear all scheduled runs?",
                                isPresented: $showClearAllConfirm,
                                titleVisibility: .visible) {
                Button("Clear \(upcoming.count) Run\(upcoming.count == 1 ? "" : "s")", role: .destructive) {
                    clearAll()
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Removes all \(upcoming.count) scheduled run\(upcoming.count == 1 ? "" : "s"). Runs you've already finished are kept.")
            }
        }
    }

    private var cancelDialogBinding: Binding<Bool> {
        Binding(get: { seriesToCancel != nil },
                set: { if !$0 { seriesToCancel = nil } })
    }

    private var emptyState: some View {
        ContentUnavailableView("Nothing Scheduled",
                               systemImage: "calendar",
                               description: Text("Schedule a run — or a whole repeating week — and it'll show up here to edit or cancel."))
    }

    private var list: some View {
        List {
            if !seriesGroups.isEmpty {
                Section("Recurring") {
                    ForEach(seriesGroups) { group in
                        seriesRow(group)
                    }
                }
            }
            if !oneOffs.isEmpty {
                Section(seriesGroups.isEmpty ? "Scheduled" : "One-off") {
                    ForEach(oneOffs) { run in
                        runRow(run)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { delete(run) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            Section {
                Button(role: .destructive) { showClearAllConfirm = true } label: {
                    Label("Clear All Scheduled Runs", systemImage: "trash")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Rows

    private func seriesRow(_ group: SeriesGroup) -> some View {
        DisclosureGroup {
            ForEach(group.runs) { run in
                runRow(run)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(run) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(seriesTitle(group.runs))
                    .font(RKFont.bodyBold).foregroundColor(RKColor.textPrimary)
                    .lineLimit(1)
                Text(seriesDetail(group.runs))
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { seriesToCancel = group } label: {
                Label("Cancel Series", systemImage: "trash")
            }
        }
    }

    private func runRow(_ run: ScheduledRun) -> some View {
        Button {
            onStart(run)
            dismiss()
        } label: {
            HStack(spacing: RKSpacing.sm) {
                Image(systemName: run.type.sfSymbol)
                    .foregroundColor(RKColor.textMuted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(RKFont.body).foregroundColor(RKColor.textPrimary)
                    Text(run.summary(unit)).font(RKFont.caption).foregroundColor(RKColor.textMuted)
                }
                Spacer()
                Text(rowDate(run.date))
                    .font(RKFont.caption)
                    .foregroundColor(run.isDue ? RKColor.accent : RKColor.textMuted)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Mutations

    private func delete(_ run: ScheduledRun) {
        context.delete(run)
        Persist.save(context)
    }

    private func cancelSeries(_ group: SeriesGroup) {
        for run in group.runs { context.delete(run) }
        Persist.save(context)
    }

    private func clearAll() {
        for run in upcoming { context.delete(run) }
        Persist.save(context)
    }

    // MARK: Formatting

    /// Distinct workout names in first-seen order, so a varied week reads
    /// "Intervals → Tempo → Long Run".
    private func seriesTitle(_ runs: [ScheduledRun]) -> String {
        var seen = Set<String>()
        return runs.map(\.title).filter { seen.insert($0).inserted }.joined(separator: " → ")
    }

    private func seriesDetail(_ runs: [ScheduledRun]) -> String {
        let days = Set(runs.map { cal.component(.weekday, from: $0.date) }).sorted()
            .map { weekdayLabels[$0 - 1] }.joined(separator: "/")
        let last = runs.map(\.date).max() ?? Date()
        return "\(days) · \(runs.count) left · ends \(Self.shortFormatter.string(from: last))"
    }

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    private static let rowFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()

    private func rowDate(_ d: Date) -> String {
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        return Self.rowFormatter.string(from: d)
    }
}
