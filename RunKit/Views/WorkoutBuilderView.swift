import SwiftUI
import SwiftData

/// Builds a reusable workout out of the same `SegmentCard`s the session setup
/// uses, so there is one editor to learn rather than two.
///
/// The difference is only what happens at the end: here the result is saved as a
/// template, whereas the session screen runs it.
struct WorkoutBuilderView: View {
    let unit: UnitSystem
    /// Label for the confirm button — "Use" when loading into a session, "Save"
    /// when the caller stores the result as a template.
    var primaryTitle: String = "Use"
    /// Whether to offer saving from inside the sheet. Off where the caller already
    /// persists what it receives, which would otherwise save twice.
    var offersSave: Bool = true
    /// Called with the finished card list and name.
    let onUse: ([ActivitySegment], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomWorkout.createdAt, order: .reverse) private var saved: [CustomWorkout]

    @State private var segments: [ActivitySegment] = ActivitySegment.starter
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var totalText: String {
        let secs = segments.filter { $0.endBasis == .time }.reduce(0) { $0 + $1.endSeconds }
        let meters = segments.filter(\.endsOnDistance).reduce(0) { $0 + $1.endMeters }
        var parts: [String] = []
        if meters > 0 {
            let d = unit.distance(meters)
            parts.append(String(format: d == d.rounded() ? "%.0f %@" : "%.2f %@", d, unit.distanceUnit))
        }
        if secs > 0 { parts.append("\(Int(secs / 60)) min") }
        return parts.isEmpty ? "Open" : parts.joined(separator: " + ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RKSpacing.md) {
                    nameField
                    cardStack
                    if !saved.isEmpty { savedSection }
                }
                .padding(.vertical, RKSpacing.md)
                .readableWidth()
            }
            .background(RKColor.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Build Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
            Button(primaryTitle) {
                if offersSave { save() }
                onUse(segments, trimmedName)
                dismiss()
            }
            .disabled(segments.isEmpty)
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { nameFocused = false }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: RKSpacing.xs) {
            TextField("Workout name", text: $name)
                .font(RKFont.bodyBold)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            Text("\(segments.count) card\(segments.count == 1 ? "" : "s") · \(totalText)")
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
        }
        .padding(.horizontal, RKSpacing.md)
    }

    private var cardStack: some View {
        VStack(spacing: RKSpacing.sm) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, _ in
                SegmentCard(
                    segment: binding(at: i),
                    index: i,
                    unit: unit,
                    onDelete: segments.count > 1 ? { remove(at: i) } : nil,
                    onMoveUp: i > 0 ? { move(from: i, to: i - 1) } : nil,
                    onMoveDown: i < segments.count - 1 ? { move(from: i, to: i + 1) } : nil,
                    onDuplicate: { duplicate(at: i) })

                AddSegmentButton { insert(after: i) }
                    .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, RKSpacing.md)
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            Text("SAVED")
                .font(RKFont.caption).foregroundColor(RKColor.textMuted).tracking(2)
            ForEach(saved) { w in
                Button {
                    segments = w.segments.isEmpty ? ActivitySegment.starter : w.segments
                    name = w.name
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.name.isEmpty ? "Untitled" : w.name)
                                .font(RKFont.bodyBold).foregroundColor(RKColor.textPrimary)
                            Text("\(w.segments.count) card\(w.segments.count == 1 ? "" : "s")")
                                .font(RKFont.caption).foregroundColor(RKColor.textMuted)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.doc")
                            .font(RKFont.caption).foregroundColor(RKColor.accent)
                    }
                    .padding(RKSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RKColor.surface)
                    .cornerRadius(RKRadius.large)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) { context.delete(w) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, RKSpacing.md)
    }

    // MARK: Card list editing

    private func binding(at i: Int) -> Binding<ActivitySegment> {
        Binding(
            get: { i < segments.count ? segments[i] : ActivitySegment() },
            set: {
                guard i < segments.count else { return }
                segments[i] = $0
            })
    }

    private func insert(after i: Int) {
        var next = ActivitySegment.added
        next.activity = segments[min(i, segments.count - 1)].activity
        segments.insert(next, at: i + 1)
    }

    private func duplicate(at i: Int) {
        guard i < segments.count else { return }
        var copy = segments[i]
        copy.id = UUID()
        segments.insert(copy, at: i + 1)
    }

    private func remove(at i: Int) {
        guard segments.count > 1, i < segments.count else { return }
        segments.remove(at: i)
    }

    private func move(from: Int, to: Int) {
        guard from < segments.count, to >= 0, to < segments.count else { return }
        segments.swapAt(from, to)
    }

    private func save() {
        context.insert(CustomWorkout(name: trimmedName.isEmpty ? "Untitled" : trimmedName,
                                     segments: segments))
        Persist.save(context)
    }
}
