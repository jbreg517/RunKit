import SwiftUI

/// The editable fields of a recorded run, and the form that edits them.
///
/// One component for two callers — the post-run review screen and History's detail
/// view — so a correction made straight after a run and one made a week later do
/// exactly the same thing.
///
/// **Duration and distance are editable; the derived numbers are not.** Pace and
/// average speed recompute from these two. Heart-rate zone seconds, splits and the
/// route are left exactly as recorded: they were measured against the original time
/// and distance, and rescaling them to a corrected total would be inventing data
/// rather than fixing it.
struct RunEdits: Equatable {
    var type: ActivityType = .run
    /// "mm:ss" or "h:mm:ss".
    var durationText = ""
    /// In the user's display units.
    var distanceText = ""
    /// Pack weight in the user's display units. Empty means "no weight carried",
    /// which is how a mis-toggled ruck gets taken back off a session.
    var ruckWeightText = ""
    var name = ""
    var notes = ""

    private init() {}
    /// Placeholder for `@State` before a run exists to edit.
    static let empty = RunEdits()

    init(_ session: ActivitySession, unit: UnitSystem) {
        type = session.type
        durationText = Self.durationText(session.activeSeconds)
        distanceText = String(format: "%.2f", unit.distance(session.distanceMeters))
        ruckWeightText = session.isRuck
            ? String(format: "%.1f", unit.weight(session.ruckWeightKg)) : ""
        name = session.customWorkoutName
        notes = session.notes ?? ""
    }

    /// Writes back only what actually parsed and actually changed, so a half-typed
    /// or emptied field can't wipe a real value.
    /// - Returns: true if anything changed.
    @discardableResult
    func apply(to session: ActivitySession, unit: UnitSystem) -> Bool {
        var changed = false

        if type != session.type {
            session.typeRaw = type.rawValue
            changed = true
        }
        if let seconds = Self.seconds(from: durationText), seconds > 0,
           abs(seconds - session.activeSeconds) > 0.5 {
            session.activeSeconds = seconds
            changed = true
        }
        if let meters = unit.meters(fromDisplay: distanceText),
           abs(meters - session.distanceMeters) > 0.5 {
            session.distanceMeters = meters
            // Marks it as a figure the user stands behind rather than one we
            // measured — which is the whole point on a treadmill, where the belt
            // knows better than the wrist.
            session.manualDistance = true
            session.distanceEstimated = false
            changed = true
        }
        // Unlike the other fields, an **empty** pack weight is a real instruction:
        // it means the run wasn't weighted after all. Only junk is ignored.
        let trimmedWeight = ruckWeightText.trimmingCharacters(in: .whitespaces)
        let newLoad: Double? = trimmedWeight.isEmpty ? 0 : unit.kilograms(fromDisplay: trimmedWeight)
        if let newLoad, abs(newLoad - session.ruckWeightKg) > 0.01 {
            session.ruckWeightKg = newLoad
            changed = true
        }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName != session.customWorkoutName {
            session.customWorkoutName = trimmedName
            changed = true
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        if trimmedNotes != (session.notes ?? "") {
            session.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            changed = true
        }
        if changed {
            session.editedAt = Date()
            recomputeEnergy(session)
        }
        return changed
    }

    /// Keeps calories consistent with whatever the duration, activity and pack
    /// weight ended up as — an edited hour left priced as a half hour would
    /// contradict everything else on the screen, and that figure feeds FuelKit.
    ///
    /// **Skipped for a watch recording.** There the calories were measured by Apple
    /// with live heart rate behind them; replacing that with a MET estimate would be
    /// throwing away the better number.
    private func recomputeEnergy(_ session: ActivitySession) {
        guard !session.energyMeasured else { return }
        session.activeEnergyKcal = HealthCalc.kcal(type: session.type,
                                                   minutes: session.activeSeconds / 60,
                                                   loadKg: session.ruckWeightKg,
                                                   bodyweight: session.bodyweightKg)
    }

    // MARK: Duration text

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// Parses "h:mm:ss", "mm:ss", or a plain number of minutes. Nil when it's junk,
    /// which the caller treats as "leave it alone".
    static func seconds(from text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":").map(String.init)
        switch parts.count {
        case 1:
            guard let minutes = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { return nil }
            return minutes * 60
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }
}

struct RunEditForm: View {
    @Binding var edits: RunEdits
    let unit: UnitSystem
    /// Hidden for a ride, which has no step-derived distance to correct and where
    /// changing the type mid-form would be more confusing than useful.
    var showsType = true

    var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.md) {
            if showsType {
                VStack(alignment: .leading, spacing: RKSpacing.xs) {
                    label("Activity")
                    Picker("Activity", selection: $edits.type) {
                        ForEach(ActivityType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            HStack(spacing: RKSpacing.md) {
                VStack(alignment: .leading, spacing: RKSpacing.xs) {
                    label("Time")
                    TextField("mm:ss", text: $edits.durationText)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: RKSpacing.xs) {
                    label("Distance (\(unit.distanceUnit))")
                    TextField("0.00", text: $edits.distanceText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: RKSpacing.xs) {
                label("Pack weight (\(unit.weightUnit))")
                TextField("None", text: $edits.ruckWeightText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty if you carried nothing. Changing this updates your loaded volume, and the calorie estimate with it.")
                    .font(.system(size: 11))
                    .foregroundColor(RKColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: RKSpacing.xs) {
                label("Name")
                TextField("Optional", text: $edits.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: RKSpacing.xs) {
                label("Notes")
                TextField("How did it feel?", text: $edits.notes, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(RKFont.caption)
            .foregroundColor(RKColor.textMuted)
    }
}
