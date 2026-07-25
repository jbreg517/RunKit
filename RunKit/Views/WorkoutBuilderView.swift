import SwiftUI
import SwiftData

/// Builds a custom multi-segment workout — e.g. 10 min warm-up, 5 mi @ 8:00,
/// 1 mi @ 7:00, 1 mi cool-down. Steps are reorderable and each ends on either a
/// duration or a distance, with an optional pace target.
struct WorkoutBuilderView: View {
    let unit: UnitSystem
    /// Called with the finished step list when the user starts it.
    let onUse: ([WorkoutStep], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomWorkout.createdAt, order: .reverse) private var saved: [CustomWorkout]

    @State private var steps: [WorkoutStep] = WorkoutStep.starter
    @State private var name = ""
    @State private var editing: WorkoutStep?

    private var totalText: String {
        let secs = steps.filter { $0.basis == .time }.reduce(0) { $0 + $1.seconds }
        let meters = steps.filter { $0.basis == .distance }.reduce(0) { $0 + $1.meters }
        var parts: [String] = []
        if meters > 0 {
            let d = unit.distance(meters)
            parts.append(String(format: d == d.rounded() ? "%.0f %@" : "%.2f %@", d, unit.distanceUnit))
        }
        if secs > 0 { parts.append("\(Int(secs / 60)) min") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " + ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($steps) { $step in
                        Button { editing = step } label: { row(step) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { steps.remove(atOffsets: $0) }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }

                    Button {
                        steps.append(WorkoutStep(kind: .work, basis: .distance, meters: 1609.344))
                    } label: {
                        Label("Add step", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Steps · \(totalText)")
                } footer: {
                    Text("Each step ends on its own time or distance. Drag to reorder, swipe to delete.")
                }

                Section("Save for reuse") {
                    TextField("Workout name (optional)", text: $name)
                    Button("Save workout") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || steps.isEmpty)
                }

                if !saved.isEmpty {
                    Section("Saved") {
                        ForEach(saved) { w in
                            Button {
                                steps = w.steps
                                name = w.name
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(w.name).foregroundColor(RKColor.textPrimary)
                                    Text("\(w.steps.count) steps")
                                        .font(RKFont.caption).foregroundColor(RKColor.textMuted)
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx { context.delete(saved[i]) }
                        }
                    }
                }
            }
            .navigationTitle("Custom Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Use") {
                        onUse(steps, name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(steps.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .sheet(item: $editing) { step in
                StepEditor(step: step, unit: unit) { updated in
                    if let i = steps.firstIndex(where: { $0.id == updated.id }) { steps[i] = updated }
                }
            }
        }
    }

    private func row(_ step: WorkoutStep) -> some View {
        HStack(spacing: RKSpacing.sm) {
            Image(systemName: step.kind.sfSymbol)
                .foregroundColor(step.kind == .work ? RKColor.accent : RKColor.textMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.kind.label)
                    .font(RKFont.bodyBold).foregroundColor(RKColor.textPrimary)
                Text(step.summary(unit))
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(RKFont.caption).foregroundColor(RKColor.textMuted)
        }
    }

    private func save() {
        let w = CustomWorkout(name: name.trimmingCharacters(in: .whitespaces), steps: steps)
        context.insert(w)
    }
}

// MARK: - Step editor

private struct StepEditor: View {
    @State var step: WorkoutStep
    let unit: UnitSystem
    let onSave: (WorkoutStep) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var minutesText = ""
    @State private var distanceText = ""
    @State private var paceText = ""

    private var unitMeters: Double { unit == .metric ? 1000 : 1609.344 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Kind", selection: $step.kind) {
                        ForEach(WorkoutStep.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Ends on", selection: $step.basis) {
                        ForEach(WorkoutStep.Basis.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section(step.basis == .time ? "Duration" : "Distance") {
                    if step.basis == .time {
                        HStack {
                            TextField("10", text: $minutesText).keyboardType(.decimalPad)
                            Text("min").foregroundColor(RKColor.textSecondary)
                        }
                    } else {
                        HStack {
                            TextField("1", text: $distanceText).keyboardType(.decimalPad)
                            Text(unit.distanceUnit).foregroundColor(RKColor.textSecondary)
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("none", text: $paceText).keyboardType(.numbersAndPunctuation)
                        Text("min \(unit.paceUnit)").foregroundColor(RKColor.textSecondary)
                    }
                } header: {
                    Text("Target pace")
                } footer: {
                    Text("Leave empty to run this step by feel. With a target, the coach nudges you when you drift off it.")
                }
            }
            .navigationTitle(step.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { commit(); dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        minutesText = String(format: "%.0f", step.seconds / 60)
        let d = unit.distance(step.meters)
        distanceText = d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
        if step.hasPaceTarget {
            let perUnit = Int((step.paceTargetSecPerMeter * unitMeters).rounded())
            paceText = String(format: "%d:%02d", perUnit / 60, perUnit % 60)
        }
    }

    private func commit() {
        if let m = Double(minutesText.replacingOccurrences(of: ",", with: ".")), m > 0 {
            step.seconds = m * 60
        }
        if let d = unit.meters(fromDisplay: distanceText), d > 0 {
            step.meters = d
        }
        step.paceTargetSecPerMeter = Self.parsePace(paceText, unitMeters: unitMeters)
        onSave(step)
    }

    /// "mm:ss" (or plain minutes) per unit → seconds per meter. 0 when empty.
    static func parsePace(_ s: String, unitMeters: Double) -> Double {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        let parts = trimmed.split(separator: ":")
        var perUnit = 0.0
        if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) {
            perUnit = m * 60 + sec
        } else if let m = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
            perUnit = m * 60
        }
        return perUnit > 0 ? perUnit / unitMeters : 0
    }
}
