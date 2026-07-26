import SwiftUI

/// One editable card in the activity builder — activity, goal, and the goal's own
/// fields, all inline. Mirrors LiftKit's per-set cards: the workout *is* the stack
/// of cards, so everything is visible and editable without drilling into a sheet.
///
/// Numeric fields are held as local text and written back on change, rather than
/// bound straight through a formatter. A formatter binding clobbers half-typed
/// input ("8." or an empty field), which makes entry feel broken.
struct SegmentCard: View {
    @Binding var segment: ActivitySegment
    let index: Int
    let unit: UnitSystem
    /// Nil hides the delete control — a session needs at least one card.
    var onDelete: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onDuplicate: (() -> Void)?

    @FocusState private var focused: Bool

    @State private var amountText = ""
    @State private var paceText = ""
    @State private var workText = ""
    @State private var restText = ""
    @State private var repsText = ""
    @State private var labelText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            header
            Divider().overlay(RKColor.surfaceElevated)
            goalRow
            goalFields
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: RKRadius.large)
                .strokeBorder(RKColor.surfaceElevated, lineWidth: 1)
        )
        .cornerRadius(RKRadius.large)
        .onAppear(perform: load)
        .onChange(of: segment.goal) { _, new in normalizeBasis(for: new); load() }
        .onChange(of: segment.basis) { _, _ in load() }
        .onChange(of: amountText) { _, _ in commitAmount() }
        .onChange(of: paceText) { _, new in
            segment.paceTargetSecPerMeter = unit.secondsPerMeter(fromPaceText: new)
        }
        .onChange(of: workText) { _, new in segment.work = clampInt(new, min: 5, max: 3600, fallback: segment.work) }
        .onChange(of: restText) { _, new in segment.rest = clampInt(new, min: 0, max: 3600, fallback: segment.rest) }
        .onChange(of: repsText) { _, new in segment.reps = clampInt(new, min: 1, max: 99, fallback: segment.reps) }
        .onChange(of: labelText) { _, new in segment.label = new }
    }

    // MARK: Header — number, name, activity, overflow

    private var header: some View {
        HStack(spacing: RKSpacing.sm) {
            Text("\(index + 1)")
                .font(RKFont.caption)
                .foregroundColor(RKColor.onAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(RKColor.accent))

            TextField(segment.activity.rawValue, text: $labelText)
                .font(RKFont.bodyBold)
                .foregroundColor(RKColor.textPrimary)
                .focused($focused)

            activityPicker
            overflowMenu
        }
    }

    private var activityPicker: some View {
        Picker("Activity", selection: $segment.activity) {
            ForEach(ActivityType.allCases) { t in
                Label(t.rawValue, systemImage: t.sfSymbol).tag(t)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(RKColor.accent)
    }

    private var overflowMenu: some View {
        Menu {
            if let onDuplicate {
                Button(action: onDuplicate) { Label("Duplicate", systemImage: "plus.square.on.square") }
            }
            if let onMoveUp {
                Button(action: onMoveUp) { Label("Move up", systemImage: "arrow.up") }
            }
            if let onMoveDown {
                Button(action: onMoveDown) { Label("Move down", systemImage: "arrow.down") }
            }
            if let onDelete {
                Divider()
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundColor(RKColor.textMuted)
        }
    }

    // MARK: Goal

    private var goalRow: some View {
        HStack {
            Label("Goal", systemImage: segment.goal.sfSymbol)
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
            Spacer()
            Picker("Goal", selection: $segment.goal) {
                ForEach(ActivitySegment.Goal.allCases) { g in
                    Label(g.label, systemImage: g.sfSymbol).tag(g)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(RKColor.accent)
        }
    }

    @ViewBuilder
    private var goalFields: some View {
        switch segment.goal {
        case .none:
            caption("Runs until you tap Next — or until you finish, if it's the last card.")
        case .distance:
            amountField(suffix: unit.distanceUnit, decimal: true)
        case .time:
            amountField(suffix: "min", decimal: false)
        case .pace:
            paceFields
        case .heartRate:
            heartRateFields
        case .intervals:
            intervalFields
        }
    }

    // MARK: Goal fields

    /// The single value a distance- or time-goal card ends on.
    private func amountField(suffix: String, decimal: Bool) -> some View {
        HStack(spacing: RKSpacing.sm) {
            TextField(decimal ? "0.0" : "0", text: $amountText)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            Text(suffix)
                .font(RKFont.caption)
                .foregroundColor(RKColor.textSecondary)
        }
    }

    private var paceFields: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack(spacing: RKSpacing.sm) {
                Text("Target").font(RKFont.caption).foregroundColor(RKColor.textMuted)
                TextField(unit == .metric ? "5:30" : "8:30", text: $paceText)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                Text("min \(unit.paceUnit)")
                    .font(RKFont.caption).foregroundColor(RKColor.textSecondary)
            }
            lengthFields
            if segment.activity == .ride, segment.paceTargetSecPerMeter > 0 {
                caption("On a ride that's \(segment.paceText(unit)).")
            }
        }
    }

    private var heartRateFields: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            Picker("Zone", selection: $segment.hrZone) {
                ForEach(1...5, id: \.self) { z in
                    Text("Z\(z)").tag(z)
                }
            }
            .pickerStyle(.segmented)
            Text(HeartRateZones.zoneName(segment.hrZone))
                .font(RKFont.caption).foregroundColor(RKColor.accent)
            lengthFields
            caption("Needs a live heart-rate source — an Apple Watch recording alongside you. Without one the card still runs, just without the nudges.")
        }
    }

    private var intervalFields: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack(spacing: RKSpacing.sm) {
                numberBox("Work", $workText, "sec")
                numberBox("Rest", $restText, "sec")
                numberBox("Reps", $repsText, "×")
            }
            presetRow
        }
    }

    private var presetRow: some View {
        HStack(spacing: RKSpacing.sm) {
            ForEach(IntervalPreset.all) { p in
                Button(p.name) {
                    workText = "\(p.work)"; restText = "\(p.rest)"; repsText = "\(p.reps)"
                }
                .font(RKFont.caption)
                .padding(.horizontal, RKSpacing.sm).padding(.vertical, 6)
                .background(RKColor.surfaceElevated)
                .foregroundColor(RKColor.textPrimary)
                .cornerRadius(RKRadius.small)
            }
        }
    }

    /// "for [Time|Distance] [value]" — how long a held target runs, since a pace or
    /// a zone can't decide on its own when the card is over.
    private var lengthFields: some View {
        VStack(alignment: .leading, spacing: RKSpacing.xs) {
            HStack {
                Text("for").font(RKFont.caption).foregroundColor(RKColor.textMuted)
                Picker("Ends on", selection: $segment.basis) {
                    ForEach(ActivitySegment.Basis.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            amountField(suffix: segment.basis == .time ? "min" : unit.distanceUnit,
                        decimal: segment.basis == .distance)
        }
    }

    private func numberBox(_ label: String, _ text: Binding<String>, _ suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(RKFont.caption).foregroundColor(RKColor.textMuted)
            HStack(spacing: 3) {
                TextField("0", text: text)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                Text(suffix).font(RKFont.caption).foregroundColor(RKColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(RKFont.caption)
            .foregroundColor(RKColor.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Text ↔ model

    /// Which field `amountText` is currently driving. Distance goals always mean
    /// metres; a held target uses whichever basis the user picked.
    private var amountIsDistance: Bool {
        switch segment.goal {
        case .distance:         return true
        case .time:             return false
        case .pace, .heartRate: return segment.basis == .distance
        case .none, .intervals: return false
        }
    }

    /// A distance or time goal *is* the basis, so keep the stored one in step —
    /// otherwise the card and the engine could disagree about which field to read.
    private func normalizeBasis(for goal: ActivitySegment.Goal) {
        switch goal {
        case .distance: segment.basis = .distance
        case .time:     segment.basis = .time
        default:        break
        }
    }

    private func load() {
        labelText = segment.label
        paceText = unit.paceText(fromSecondsPerMeter: segment.paceTargetSecPerMeter)
        workText = "\(segment.work)"
        restText = "\(segment.rest)"
        repsText = "\(segment.reps)"
        if amountIsDistance {
            let d = unit.distance(segment.meters)
            amountText = d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
        } else {
            amountText = String(format: "%.0f", (segment.seconds / 60).rounded())
        }
    }

    /// Empty or unparseable input leaves the stored value alone, so clearing the
    /// field to retype it doesn't reset the card to zero.
    private func commitAmount() {
        if amountIsDistance {
            if let m = unit.meters(fromDisplay: amountText), m > 0 { segment.meters = m }
        } else if let m = Double(amountText.replacingOccurrences(of: ",", with: ".")), m > 0 {
            segment.seconds = m * 60
        }
    }

    private func clampInt(_ text: String, min lo: Int, max hi: Int, fallback: Int) -> Int {
        guard let v = Int(text) else { return fallback }
        return Swift.min(hi, Swift.max(lo, v))
    }
}

/// The `+` that sits under each card and appends the next one.
struct AddSegmentButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(RKColor.accent)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .strokeBorder(RKColor.accent.opacity(0.45), lineWidth: 1.5)
                )
        }
        .accessibilityLabel("Add activity")
    }
}
