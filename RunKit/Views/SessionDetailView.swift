import SwiftUI
import SwiftData

/// Detail for a completed activity, reached from History. Supports edit, delete,
/// and "Do Again"; GPX export and Health route-writing land in later phases.
struct SessionDetailView: View {
    let session: ActivitySession
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var showEdit = false
    @State private var showDeleteConfirm = false

    private var points: [RoutePoint] { session.sortedRoute }
    private var hasRoute: Bool { points.count >= 2 }
    private var splits: [Split] { RouteMath.splits(points, unit: unit) }

    var body: some View {
        ScrollView {
            VStack(spacing: RKSpacing.lg) {
                if hasRoute {
                    RouteMapView(points: points)
                        .padding(.horizontal, RKSpacing.md)
                }
                summaryTiles
                secondaryStats
                if !splits.isEmpty { splitsCard }
                if let notes = session.notes, !notes.isEmpty { notesCard(notes) }
                doAgainButton
            }
            .padding(.vertical, RKSpacing.md)
            .readableWidth()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(RKColor.background.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            SessionEditSheet(session: session, unit: unit, onSave: applyEdits)
        }
        .alert("Delete this activity?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the activity and its route. This can’t be undone.")
        }
    }

    private var doAgainButton: some View {
        Button("Do \(session.type.rawValue) Again") {
            router.doAgain(session.type)
            dismiss()
        }
        .buttonStyle(RKPrimaryButtonStyle())
        .padding(.horizontal, RKSpacing.md)
        .padding(.top, RKSpacing.sm)
    }

    // MARK: Edit / delete

    private func applyEdits(type: ActivityType, notes: String, distanceMeters: Double?) {
        session.typeRaw = type.rawValue
        session.notes = notes.isEmpty ? nil : notes
        if let meters = distanceMeters {
            session.distanceMeters = meters
            session.manualDistance = true
            session.distanceEstimated = false   // user-entered is authoritative
        }
        session.activeEnergyKcal = HealthCalc.kcal(type: type, minutes: session.activeSeconds / 60)
        try? context.save()
    }

    private func deleteSession() {
        context.delete(session)
        try? context.save()
        dismiss()
    }

    private var title: String {
        session.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Summary

    private var summaryTiles: some View {
        HStack(spacing: RKSpacing.md) {
            tile("Distance", unit.distanceString(session.distanceMeters),
                 caption: session.distanceEstimated ? "~ estimated" : nil)
            tile("Duration", durationString(session.activeSeconds))
            tile(session.type == .ride ? "Avg Speed" : "Avg Pace",
                 session.type == .ride
                    ? unit.speedString(seconds: session.activeSeconds, meters: session.distanceMeters)
                    : unit.paceString(seconds: session.activeSeconds, meters: session.distanceMeters))
        }
        .padding(.horizontal, RKSpacing.md)
    }

    private var secondaryStats: some View {
        let elev = RouteMath.elevationGain(points)
        let maxSpd = RouteMath.maxSpeed(points, type: session.type)
        return VStack(alignment: .leading, spacing: RKSpacing.sm) {
            if session.distanceEstimated {
                Label("Some distance was estimated where GPS was unavailable.",
                      systemImage: "exclamationmark.triangle")
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
            }
            HStack(spacing: RKSpacing.md) {
                stat("\(Int(session.activeEnergyKcal))", "kcal", "flame.fill")
                if hasRoute { stat(unit.elevationString(elev), "elev gain", "mountain.2.fill") }
                if session.type != .ride { stat("\(session.steps)", "steps", "shoeprints.fill") }
                if maxSpd > 0 { stat(unit.speedString(metersPerSecond: maxSpd), "max speed", "speedometer") }
            }
        }
        .padding(.horizontal, RKSpacing.md)
    }

    // MARK: Splits

    private var splitsCard: some View {
        let perUnit = splits.map { $0.seconds / max(unit.distance($0.meters), 0.0001) }
        let fastest = perUnit.min() ?? 0
        let slowest = perUnit.max() ?? 1
        return VStack(alignment: .leading, spacing: RKSpacing.sm) {
            Text("Splits").font(RKFont.heading).foregroundColor(RKColor.textPrimary)
            ForEach(Array(splits.enumerated()), id: \.element.id) { i, split in
                let raw = slowest > fastest ? 1 - (perUnit[i] - fastest) / (slowest - fastest) : 1
                let frac = min(1, max(0.06, raw))
                HStack(spacing: RKSpacing.md) {
                    Text(split.partial
                         ? unit.distanceString(split.meters)
                         : "\(split.index)")
                        .font(RKFont.bodyBold)
                        .foregroundColor(RKColor.textPrimary)
                        .frame(width: 44, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(RKColor.surfaceElevated)
                            Capsule().fill(RKColor.accent)
                                .frame(width: max(8, geo.size.width * frac))
                        }
                    }
                    .frame(height: 8)
                    Text(unit.paceString(seconds: split.seconds, meters: split.meters))
                        .font(RKFont.caption)
                        .foregroundColor(RKColor.textSecondary)
                        .frame(width: 76, alignment: .trailing)
                }
            }
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            Text("Notes").font(RKFont.heading).foregroundColor(RKColor.textPrimary)
            Text(notes).font(RKFont.body).foregroundColor(RKColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    // MARK: Building blocks

    private func tile(_ title: String, _ value: String, caption: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(RKColor.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(RKFont.caption).foregroundColor(RKColor.textMuted)
            if let caption {
                Text(caption).font(RKFont.caption).foregroundColor(RKColor.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(RKColor.accent)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(RKColor.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(RKFont.caption).foregroundColor(RKColor.textMuted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
    }

    private func durationString(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Staged-draft editor for a completed session. Changes apply only on Save.
/// Distance is editable for rides and manual/no-GPS sessions; GPS-derived
/// distance stays read-only (it comes from the route).
private struct SessionEditSheet: View {
    let session: ActivitySession
    let unit: UnitSystem
    let onSave: (ActivityType, String, Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var type: ActivityType
    @State private var notes: String
    @State private var distanceText: String

    init(session: ActivitySession, unit: UnitSystem,
         onSave: @escaping (ActivityType, String, Double?) -> Void) {
        self.session = session
        self.unit = unit
        self.onSave = onSave
        _type = State(initialValue: session.type)
        _notes = State(initialValue: session.notes ?? "")
        _distanceText = State(initialValue: String(format: "%.2f", unit.distance(session.distanceMeters)))
    }

    /// Rides and sessions without a GPS track allow a manual distance.
    private var distanceEditable: Bool { session.type == .ride || !session.usedGPS }

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    Picker("Type", selection: $type) {
                        ForEach(ActivityType.allCases) { t in
                            Label(t.rawValue, systemImage: t.sfSymbol).tag(t)
                        }
                    }
                }

                if distanceEditable {
                    Section("Distance (\(unit.distanceUnit))") {
                        TextField("Distance", text: $distanceText)
                            .keyboardType(.decimalPad)
                    }
                } else {
                    Section {
                        LabeledContent("Distance", value: unit.distanceString(session.distanceMeters))
                    } footer: {
                        Text("Distance is measured from your GPS route and can’t be edited.")
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let meters = distanceEditable ? unit.meters(fromDisplay: distanceText) : nil
                        onSave(type, notes, meters)
                        dismiss()
                    }
                }
            }
        }
    }
}
