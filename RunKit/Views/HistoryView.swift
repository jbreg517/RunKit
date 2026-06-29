import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    @Query(sort: \ActivitySession.startedAt, order: .reverse) private var sessions: [ActivitySession]

    private var completed: [ActivitySession] { sessions.filter { $0.endedAt != nil } }

    var body: some View {
        NavigationStack {
            Group {
                if completed.isEmpty {
                    ContentUnavailableView(
                        "No Activities Yet",
                        systemImage: "figure.run",
                        description: Text("Start a walk, run or ride and it’ll show up here.")
                    )
                } else {
                    List {
                        ForEach(completed) { s in
                            NavigationLink(value: s) { row(s) }
                        }
                        .onDelete(perform: delete)
                    }
                    .scrollContentBackground(.hidden)
                    .navigationDestination(for: ActivitySession.self) { s in
                        SessionDetailView(session: s)
                    }
                }
            }
            .navigationTitle("History")
            .background(RKColor.background.ignoresSafeArea())
        }
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

    private func durationString(_ t: TimeInterval) -> String {
        "\(Int(t) / 60)m \(Int(t) % 60)s"
    }
}
