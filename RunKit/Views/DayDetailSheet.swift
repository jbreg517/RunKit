import SwiftUI
import SwiftData

/// What happened — or is planned — on one day. Opened by tapping a calendar day.
struct DayDetailSheet: View {
    let day: Date
    let unit: UnitSystem
    let sessions: [ActivitySession]
    let scheduled: [ScheduledRun]
    /// Start a scheduled run now.
    let onStart: (ScheduledRun) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var showSchedule = false

    private var cal: Calendar { .current }

    private var daySessions: [ActivitySession] {
        sessions.filter { cal.isDate($0.startedAt, inSameDayAs: day) }
    }

    private var dayScheduled: [ScheduledRun] {
        scheduled.filter { cal.isDate($0.date, inSameDayAs: day) }
    }

    private var title: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: day)
    }

    private var isPast: Bool {
        cal.startOfDay(for: day) < cal.startOfDay(for: Date())
    }

    var body: some View {
        NavigationStack {
            List {
                if !dayScheduled.isEmpty {
                    Section("Planned") {
                        ForEach(dayScheduled) { run in
                            Button {
                                onStart(run)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: run.isCompleted
                                          ? "checkmark.circle.fill" : run.type.sfSymbol)
                                        .foregroundColor(run.isCompleted ? RKColor.success : RKColor.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(run.title).foregroundColor(RKColor.textPrimary)
                                        Text(run.summary(unit))
                                            .font(RKFont.caption)
                                            .foregroundColor(RKColor.textMuted)
                                    }
                                    Spacer()
                                    if !run.isCompleted {
                                        Image(systemName: "play.circle.fill")
                                            .foregroundColor(RKColor.accent)
                                    }
                                }
                            }
                            .disabled(run.isCompleted)
                        }
                        .onDelete { idx in
                            for i in idx { context.delete(dayScheduled[i]) }
                        }
                    }
                }

                if !daySessions.isEmpty {
                    Section("Recorded") {
                        ForEach(daySessions) { s in
                            NavigationLink {
                                SessionDetailView(session: s)
                            } label: {
                                HStack {
                                    Image(systemName: s.type.sfSymbol)
                                        .foregroundColor(RKColor.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.type.rawValue).foregroundColor(RKColor.textPrimary)
                                        Text("\(unit.distanceString(s.distanceMeters)) · \(Int(s.activeSeconds / 60)) min")
                                            .font(RKFont.caption)
                                            .foregroundColor(RKColor.textMuted)
                                    }
                                }
                            }
                        }
                    }
                }

                if daySessions.isEmpty && dayScheduled.isEmpty {
                    Section {
                        Text(isPast ? "Nothing recorded this day."
                             : "Nothing planned yet.")
                            .font(RKFont.caption)
                            .foregroundColor(RKColor.textMuted)
                    }
                }

                if !isPast {
                    Section {
                        Button {
                            showSchedule = true
                        } label: {
                            Label("Schedule a run", systemImage: "calendar.badge.plus")
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(isPresented: $showSchedule) {
                ScheduleRunSheet(unit: unit, initialDate: day)
            }
        }
    }
}
