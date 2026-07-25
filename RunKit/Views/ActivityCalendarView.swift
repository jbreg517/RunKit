import SwiftUI

/// Month grid of activity — a gold dot on every day with a recorded session.
///
/// This is the surface the v2 planning calendar extends: once `PlannedWorkout`
/// exists, planned days layer onto the same grid (hollow marker = planned,
/// filled = completed). Kept deliberately simple until then.
struct ActivityCalendarView: View {
    let sessions: [ActivitySession]

    @State private var month: Date = Calendar.current.startOfDay(for: Date())

    private var cal: Calendar { .current }

    /// Days with at least one session, keyed by start-of-day.
    private var activeDays: Set<Date> {
        Set(sessions.map { cal.startOfDay(for: $0.startedAt) })
    }

    /// Leading blanks to align the 1st under its weekday, then each day.
    private var cells: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month),
              let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let first = interval.start
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        var out = [Date?](repeating: nil, count: lead)
        for offset in 0..<range.count {
            out.append(cal.date(byAdding: .day, value: offset, to: first))
        }
        return out
    }

    /// Weekday initials rotated to the locale's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortWeekdaySymbols
        let shift = cal.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month)
    }

    /// Sessions recorded in the displayed month.
    private var monthCount: Int {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return 0 }
        return sessions.filter { interval.contains($0.startedAt) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            header

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                      spacing: 6) {
                // Indexed, not id: \.self — English weekday initials repeat
                // ("S M T W T F S"), and duplicate IDs break the grid.
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(RKFont.caption)
                        .foregroundColor(RKColor.textMuted)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date { dayCell(date) } else { Color.clear.frame(height: 32) }
                }
            }

            Text(monthCount == 0
                 ? "No activity recorded this month."
                 : "\(monthCount) session\(monthCount == 1 ? "" : "s") this month")
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left").foregroundColor(RKColor.accent)
            }
            Spacer()
            Text(monthTitle)
                .font(RKFont.bodyBold)
                .foregroundColor(RKColor.textPrimary)
            Spacer()
            Button { shift(1) } label: {
                Image(systemName: "chevron.right").foregroundColor(RKColor.accent)
            }
            // Forward navigation past the current month has nothing to show yet.
            .disabled(isCurrentMonth)
            .opacity(isCurrentMonth ? 0.3 : 1)
        }
    }

    private var isCurrentMonth: Bool {
        cal.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private func dayCell(_ date: Date) -> some View {
        let day = cal.startOfDay(for: date)
        let active = activeDays.contains(day)
        let isToday = cal.isDateInToday(date)
        return Text("\(cal.component(.day, from: date))")
            .font(RKFont.caption)
            .foregroundColor(active ? RKColor.onAccent
                             : (isToday ? RKColor.accent : RKColor.textSecondary))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                Circle()
                    .fill(active ? RKColor.accent : Color.clear)
                    .frame(width: 32, height: 32)
            )
            .overlay(
                Circle()
                    .stroke(isToday && !active ? RKColor.accent : Color.clear, lineWidth: 1.5)
                    .frame(width: 32, height: 32)
            )
    }

    private func shift(_ months: Int) {
        if let next = cal.date(byAdding: .month, value: months, to: month) {
            month = next
        }
    }
}
