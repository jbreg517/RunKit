import SwiftUI
import SwiftData
import CoreLocation

/// Goal semantics for the spoken completion cue.
enum GoalKind: String, CaseIterable, Identifiable {
    case none, distance, time
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:     return "None"
        case .distance: return "Distance"
        case .time:     return "Time"
        }
    }
}

/// Setting up and running a session.
///
/// Since v0.45 the setup is a stack of `ActivitySegment` cards — activity, goal,
/// goal's fields — with a `+` under each. One card with no goal is "just go for a
/// run"; several cards is a structured workout. There's no separate Custom mode,
/// because the card stack *is* the custom mode, and the simple case is only the
/// one-card case. The live engine below runs a single loop over that list rather
/// than the five parallel run-type paths it replaced.
struct ActivitySessionView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage("gpsEnabled") private var gpsEnabled = true
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage("voiceAnnouncements") private var voiceOn = true
    @AppStorage("maxHeartRate") private var maxHeartRateOverride = 0.0
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    @State private var location = LocationService.shared
    @State private var motion = MotionService.shared
    @State private var liveHR = LiveHeartRateService.shared
    /// Pedometer reading when the session began, so we can measure the delta.
    @State private var motionStartMeters: Double = 0

    // MARK: Setup state

    @State private var segments: [ActivitySegment] = ActivitySegment.starter
    @State private var workoutName = ""
    @State private var showLibrary = false
    @State private var showSaveTemplate = false
    @State private var templateName = ""
    /// Name of the picked template or recipe, shown until the cards are edited.
    @State private var sourceName: String?
    /// Set when this session was launched from a scheduled run, so finishing it
    /// marks that schedule complete.
    @State private var activeScheduleID: UUID?
    @FocusState private var fieldFocused: Bool

    // MARK: Session lifecycle

    @State private var session: ActivitySession?
    @State private var startDate: Date?
    /// When the session was paused, and the running total of paused time.
    /// `elapsed` subtracts `pausedTotal`, so every downstream consumer — the card
    /// engine, goals, pace — freezes for free while paused.
    @State private var pausedAt: Date?
    @State private var pausedTotal: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var ticker: Timer?
    @State private var countdown: Int?

    // MARK: Live derived state

    @State private var mapExpanded = true
    @State private var displayedSpeedMps: Double = 0   // refreshed every 3s, smoothed
    @State private var lastPaceUpdate: TimeInterval = 0
    @State private var announcedUnits = 0
    @State private var goalAnnounced = false
    @State private var lastNudge: TimeInterval = 0

    // MARK: Card engine state

    @State private var segIndex = 0
    @State private var segStartElapsed: TimeInterval = 0
    @State private var segStartMeters: Double = 0
    @State private var segmentsDone = false
    /// Seconds spent on each activity, banked as cards finish. A run/walk workout
    /// burns very differently from either alone, so calories are summed per card
    /// rather than taken from one session-wide type.
    @State private var activitySeconds: [String: TimeInterval] = [:]
    // Intervals sub-machine, scoped to the current card.
    @State private var intPhaseIsWork = true
    @State private var intRep = 1
    @State private var phaseEndsAt: TimeInterval = 0
    @State private var intervalsDone = false
    /// Zone bounds for the heart-rate goal, resolved once at session start.
    @State private var zones: [HeartRateZones.Zone] = []

    private var unitMeters: Double { unit.metersPerUnit }

    // MARK: - Derived

    private var currentSegment: ActivitySegment? {
        guard !segmentsDone, segIndex < segments.count else { return nil }
        return segments[segIndex]
    }

    /// Activity for the *current* card — drives pace-vs-speed display and cues.
    private var liveActivity: ActivityType {
        currentSegment?.activity ?? segments.first?.activity ?? .run
    }

    /// Activity the session as a whole is filed under in Health and History.
    private var sessionActivity: ActivityType { segments.first?.activity ?? .run }

    private var workoutType: WorkoutType { ActivitySegment.workoutType(for: segments) }

    /// Live distance. GPS when it's on; otherwise the pedometer delta since the
    /// session started — the *expected* source for a GPS-off walk/run, not a
    /// failure. A ride has neither, so it reports 0.
    private var sessionMeters: Double {
        if session?.usedGPS == true { return location.distanceMeters }
        guard segments.contains(where: { $0.activity.pedometerDistance }) else { return 0 }
        return max(0, motion.distanceMeters - motionStartMeters)
    }

    private var elapsedInSegment: TimeInterval { elapsed - segStartElapsed }
    private var metersInSegment: Double { sessionMeters - segStartMeters }

    private var distanceSegments: [ActivitySegment] { segments.filter(\.endsOnDistance) }
    private var needsDistance: Bool { !distanceSegments.isEmpty }

    /// A ride measures distance only by GPS, so a distance card on a ride with GPS
    /// off could never complete. Walk/run still work via the pedometer.
    private var distanceUnavailable: Bool {
        !gpsEnabled && distanceSegments.contains { !$0.activity.pedometerDistance }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                RKColor.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: RKSpacing.lg) {
                        if session == nil { setup } else { live }
                    }
                    .padding(.vertical, RKSpacing.lg)
                    .readableWidth()
                    .contentShape(Rectangle())
                    .onTapGesture { fieldFocused = false }
                }
                .scrollDismissesKeyboard(.interactively)
                if let c = countdown { countdownOverlay(c) }
            }
            .navigationTitle("Activity")
            .toolbar { toolbarContent }
            .interactiveDismissDisabled(session != nil)
            .onAppear {
                consumePendingWorkout()
                // Warm the pedometer so a GPS-off session has a live baseline to
                // measure its distance delta against.
                motion.startToday()
            }
            .task { await HealthService.shared.requestAuthorization() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            // Only offered when idle: a running session lives in this view's
            // state, so dismissing mid-run would discard it.
            if session == nil {
                Button("Close") { dismiss() }
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { fieldFocused = false }
        }
    }

    /// Applies a workout queued by a template, prebuilt recipe, scheduled run or
    /// History's "Do Again" — once, and only while idle.
    private func consumePendingWorkout() {
        guard session == nil, let p = router.pendingWorkout else { return }
        router.pendingWorkout = nil
        segments = p.resolvedSegments
        workoutName = p.name
        activeScheduleID = p.scheduleID
        sourceName = p.name.isEmpty ? nil : p.name
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(spacing: RKSpacing.lg) {
            gpsRow
            libraryRow
            cardStack
            setupWarnings
            startButton
        }
        .sheet(isPresented: $showLibrary) {
            WorkoutLibraryView(unit: unit) { apply($0) }
        }
        .alert("Save as template", isPresented: $showSaveTemplate) {
            TextField("Name", text: $templateName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveTemplate() }
        } message: {
            Text("Keeps these \(segments.count) card\(segments.count == 1 ? "" : "s") on your Today screen to run again.")
        }
    }

    private var gpsRow: some View {
        Toggle("Use GPS (route + distance)", isOn: $gpsEnabled)
            .tint(RKColor.accent)
            .padding(.horizontal, RKSpacing.md)
    }

    /// Library entry point. A single row, so the setup stays about the cards.
    private var libraryRow: some View {
        Button {
            fieldFocused = false
            showLibrary = true
        } label: {
            HStack(spacing: RKSpacing.xs) {
                Image(systemName: "books.vertical.fill")
                Text(sourceName ?? "Browse workouts")
                Spacer()
                Image(systemName: "chevron.right").font(RKFont.caption)
            }
            .font(RKFont.caption)
            .foregroundColor(sourceName == nil ? RKColor.accent : RKColor.textPrimary)
            .padding(.horizontal, RKSpacing.md)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(RKColor.surface)
            .cornerRadius(RKRadius.large)
        }
        .padding(.horizontal, RKSpacing.md)
    }

    /// The cards themselves, each followed by the `+` that adds the next one.
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

            if segments.count > 1 {
                Button {
                    templateName = workoutName
                    showSaveTemplate = true
                } label: {
                    Label("Save as template", systemImage: "square.and.arrow.down")
                        .font(RKFont.caption)
                }
                .padding(.top, RKSpacing.xs)
            }
        }
        .padding(.horizontal, RKSpacing.md)
    }

    @ViewBuilder
    private var setupWarnings: some View {
        if distanceUnavailable {
            warning("A ride has no way to measure distance without GPS, so a distance card would never finish. Turn GPS on, or give that card a time goal.")
        } else if needsDistance && !gpsEnabled {
            warning("GPS is off — distance comes from your step counter, so it's an estimate and there'll be no route map.")
        }
        if segments.contains(where: { $0.goal == .heartRate }) {
            warning("A heart-rate card needs a Watch recording alongside you. Without one it still runs — it just won't nudge you about zones.")
        }
    }

    private var startButton: some View {
        Button("Start \(sessionActivity.rawValue)") { startCountdown() }
            .buttonStyle(RKPrimaryButtonStyle())
            .padding(.horizontal, RKSpacing.md)
            .disabled(segments.isEmpty || distanceUnavailable)
    }

    /// Inline caution about a setup that can't measure what it needs.
    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: RKSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(RKColor.accent)
            Text(text)
                .font(RKFont.caption)
                .foregroundColor(RKColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    // MARK: Card list editing

    /// Index-based binding rather than `ForEach($segments)`, so the row also gets
    /// its position for the number badge and the move controls.
    ///
    /// Deliberately does *not* clear `sourceName`: the card writes its parsed text
    /// back on appear, so clearing here would wipe the name of a workout the
    /// instant it loaded. Only structural edits drop the name.
    private func binding(at i: Int) -> Binding<ActivitySegment> {
        Binding(
            get: { i < segments.count ? segments[i] : ActivitySegment() },
            set: {
                guard i < segments.count else { return }
                segments[i] = $0
            })
    }

    private func insert(after i: Int) {
        fieldFocused = false
        var next = ActivitySegment.added
        next.activity = segments[min(i, segments.count - 1)].activity
        segments.insert(next, at: i + 1)
        sourceName = nil
    }

    private func duplicate(at i: Int) {
        guard i < segments.count else { return }
        var copy = segments[i]
        copy.id = UUID()
        segments.insert(copy, at: i + 1)
        sourceName = nil
    }

    private func remove(at i: Int) {
        guard segments.count > 1, i < segments.count else { return }
        segments.remove(at: i)
        sourceName = nil
    }

    private func move(from: Int, to: Int) {
        guard from < segments.count, to >= 0, to < segments.count else { return }
        segments.swapAt(from, to)
        sourceName = nil
    }

    /// Load a library workout into the cards. Everything a recipe sets stays
    /// editable — picking one is a starting point, not a lock.
    private func apply(_ r: WorkoutRecipe) {
        let built = ActivitySegment.from(recipe: r)
        segments = built.isEmpty ? ActivitySegment.starter : built
        workoutName = r.name
        sourceName = r.name
    }

    private func saveTemplate() {
        let name = templateName.trimmingCharacters(in: .whitespaces)
        workoutName = name
        context.insert(CustomWorkout(name: name.isEmpty ? "Untitled" : name, segments: segments))
        try? context.save()
    }

    // MARK: - Live

    private var live: some View {
        VStack(spacing: RKSpacing.lg) {
            if session?.usedGPS == true { mapCard }
            liveBanners
            clock
            metricsRow
            if currentSegment?.endBasis != nil { goalProgress }
            liveControls
        }
    }

    @ViewBuilder
    private var liveBanners: some View {
        if let seg = currentSegment {
            if seg.goal == .intervals { intervalBanner }
            segmentBanner
            if seg.goal == .pace { paceBanner(seg) }
            if seg.goal == .heartRate { heartRateBanner(seg) }
        } else if segmentsDone {
            segmentBanner
        }
    }

    private var clock: some View {
        VStack(spacing: RKSpacing.xs) {
            Text(timeString(elapsed))
                .font(.system(size: 60, weight: .black, design: .monospaced))
                .foregroundColor(pausedAt == nil ? RKColor.textPrimary : RKColor.textMuted)
                .contentTransition(.numericText())
            if pausedAt != nil {
                Text("PAUSED")
                    .font(RKFont.caption).bold()
                    .foregroundColor(RKColor.accent)
            }
        }
    }

    private var liveControls: some View {
        VStack(spacing: RKSpacing.sm) {
            if segments.count > 1 && !segmentsDone {
                Button("Next card") { advanceSegment() }
                    .buttonStyle(RKSecondaryButtonStyle())
            }
            HStack(spacing: RKSpacing.sm) {
                Button(pausedAt == nil ? "Pause" : "Resume") { togglePause() }
                    .buttonStyle(RKSecondaryButtonStyle())
                Button("Finish") { finish() }
                    .buttonStyle(RKPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, RKSpacing.md)
    }

    /// Current card, what's left of it, and what's next.
    private var segmentBanner: some View {
        let seg = currentSegment
        let isWork = seg.map { $0.goal != ActivitySegment.Goal.none } ?? false
        return VStack(spacing: RKSpacing.xs) {
            Text(segmentsDone ? "DONE" : (seg.map { headline($0) } ?? ""))
                .font(.system(size: 26, weight: .black))
                .multilineTextAlignment(.center)
                .foregroundColor(isWork && !segmentsDone ? RKColor.accent : RKColor.textSecondary)
            if let seg, !segmentsDone {
                Text(remainingText(seg))
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
                if segIndex + 1 < segments.count {
                    Text("Next: \(headline(segments[segIndex + 1])) · \(segments[segIndex + 1].summary(unit))")
                        .font(RKFont.caption).foregroundColor(RKColor.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.md)
        .background((isWork && !segmentsDone) ? RKColor.accent.opacity(0.15) : RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private func headline(_ seg: ActivitySegment) -> String {
        seg.label.trimmingCharacters(in: .whitespaces).isEmpty
            ? seg.activity.rawValue.uppercased()
            : seg.label.uppercased()
    }

    /// "3:42 left · Card 2 of 4", or the open-card equivalent.
    private func remainingText(_ seg: ActivitySegment) -> String {
        let position = segments.count > 1 ? "  ·  Card \(segIndex + 1) of \(segments.count)" : ""
        guard let end = seg.endBasis else {
            if seg.goal == .intervals { return seg.summary(unit) + position }
            return (segments.count > 1 ? "Open" : "No target") + position
        }
        if end == .distance {
            return unit.distanceString(max(0, seg.endMeters - metersInSegment)) + " left" + position
        }
        return timeString(max(0, seg.endSeconds - elapsedInSegment)) + " left" + position
    }

    private var intervalBanner: some View {
        let remaining = max(0, Int((phaseEndsAt - elapsed).rounded()))
        let reps = currentSegment?.reps ?? 0
        return VStack(spacing: RKSpacing.xs) {
            Text(intervalsDone ? "INTERVALS DONE" : (intPhaseIsWork ? "WORK" : "REST"))
                .font(.system(size: 30, weight: .black))
                .foregroundColor(intPhaseIsWork && !intervalsDone ? RKColor.accent : RKColor.textSecondary)
            if !intervalsDone {
                Text("Rep \(intRep) of \(reps)  ·  \(remaining)s")
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.md)
        .background((intPhaseIsWork && !intervalsDone) ? RKColor.accent.opacity(0.15) : RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private func paceBanner(_ seg: ActivitySegment) -> some View {
        let target = seg.paceTargetSecPerMeter * unitMeters
        let current = displayedSpeedMps > 0.2 ? unitMeters / displayedSpeedMps : 0
        let state = paceState(current: current, target: target)
        return VStack(alignment: .leading, spacing: RKSpacing.sm) {
            targetRow("Target", unit.paceString(secondsPerUnit: target), RKColor.textPrimary)
            targetRow("You", current > 0 ? unit.paceString(secondsPerUnit: current) : "—", state.1)
            Text(state.0).font(RKFont.bodyBold).foregroundColor(state.1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private func paceState(current: Double, target: Double) -> (String, Color) {
        guard current > 0, target > 0 else { return ("—", RKColor.textMuted) }
        let r = current / target
        if r > 1.08 { return ("Pick it up", RKColor.danger) }
        if r < 0.92 { return ("Ease off", RKColor.accent) }
        return ("On pace", RKColor.success)
    }

    private func heartRateBanner(_ seg: ActivitySegment) -> some View {
        let zone = zones.first { $0.index == seg.hrZone }
        let bpm = liveHR.bpm
        let state = hrState(bpm: bpm, zone: zone)
        return VStack(alignment: .leading, spacing: RKSpacing.sm) {
            targetRow("Target", zoneRangeText(zone, name: HeartRateZones.zoneName(seg.hrZone)),
                      RKColor.textPrimary)
            targetRow("You", bpm > 0 ? "\(Int(bpm)) bpm" : "—", state.1)
            Text(state.0).font(RKFont.bodyBold).foregroundColor(state.1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private func zoneRangeText(_ zone: HeartRateZones.Zone?, name: String) -> String {
        guard let zone else { return name }
        return "\(name) · \(Int(zone.lower))–\(Int(zone.upper))"
    }

    private func hrState(bpm: Double, zone: HeartRateZones.Zone?) -> (String, Color) {
        guard bpm > 0 else { return ("Waiting for a heart-rate source", RKColor.textMuted) }
        guard let zone else { return ("No zones — set your max HR in Settings", RKColor.textMuted) }
        if bpm < zone.lower { return ("Pick it up", RKColor.danger) }
        if bpm > zone.upper { return ("Ease off", RKColor.accent) }
        return ("In zone", RKColor.success)
    }

    private func targetRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(RKFont.caption).foregroundColor(RKColor.textMuted)
            Spacer()
            Text(value)
                .font(RKFont.bodyBold).foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private var mapCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut) { mapExpanded.toggle() }
            } label: {
                HStack {
                    Label("Map", systemImage: "map.fill")
                        .font(RKFont.bodyBold)
                        .foregroundColor(RKColor.textPrimary)
                    Spacer()
                    Image(systemName: mapExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(RKColor.textSecondary)
                }
                .padding(RKSpacing.md)
            }
            if mapExpanded {
                LiveRouteMapView(coordinates: location.coordinates,
                                 current: location.lastLocation?.coordinate)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: RKRadius.medium))
                    .padding([.horizontal, .bottom], RKSpacing.md)
            }
        }
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private var metricsRow: some View {
        HStack(spacing: RKSpacing.md) {
            metric(unit.distanceString(sessionMeters), "Distance")
            metric(currentPaceString, liveActivity == .ride ? "Cur Speed" : "Cur Pace")
            metric(overallPaceString, liveActivity == .ride ? "Avg Speed" : "Avg Pace")
        }
        .padding(.horizontal, RKSpacing.md)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(RKColor.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(RKFont.caption).foregroundColor(RKColor.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
    }

    private var goalProgress: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack {
                Text(segments.count > 1 ? "Card \(segIndex + 1)" : "Goal")
                    .font(RKFont.bodyBold).foregroundColor(RKColor.textPrimary)
                Spacer()
                Text(goalLabel()).font(RKFont.caption).foregroundColor(RKColor.textSecondary)
            }
            ProgressView(value: goalFraction()).tint(RKColor.accent)
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private func countdownOverlay(_ c: Int) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            Text("\(c)")
                .font(.system(size: 160, weight: .black, design: .rounded))
                .foregroundColor(RKColor.accent)
                .transition(.scale.combined(with: .opacity))
                .id(c)
        }
    }

    // MARK: - Derived strings

    private var currentPaceString: String {
        guard displayedSpeedMps > 0.2 else { return "--" }
        if liveActivity == .ride { return unit.speedString(metersPerSecond: displayedSpeedMps) }
        return unit.paceString(secondsPerUnit: unitMeters / displayedSpeedMps)
    }

    private var overallPaceString: String {
        let d = sessionMeters
        if liveActivity == .ride { return unit.speedString(seconds: elapsed, meters: d) }
        return unit.paceString(seconds: elapsed, meters: d)
    }

    private func goalFraction() -> Double {
        guard let seg = currentSegment, let end = seg.endBasis else { return 0 }
        if end == .distance {
            return seg.endMeters > 0 ? min(1, metersInSegment / seg.endMeters) : 0
        }
        return seg.endSeconds > 0 ? min(1, elapsedInSegment / seg.endSeconds) : 0
    }

    private func goalLabel() -> String {
        guard let seg = currentSegment, let end = seg.endBasis else { return "" }
        if end == .distance {
            return "\(unit.distanceString(metersInSegment)) / \(unit.distanceString(seg.endMeters))"
        }
        return "\(timeString(elapsedInSegment)) / \(timeString(seg.endSeconds))"
    }

    // MARK: - Lifecycle

    /// 3-2-1 visual countdown, then the session begins.
    private func startCountdown() {
        fieldFocused = false
        withAnimation { countdown = 3 }
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            guard let c = countdown else { timer.invalidate(); return }
            if c <= 1 {
                timer.invalidate()
                withAnimation { countdown = nil }
                beginActiveSession()
            } else {
                withAnimation { countdown = c - 1 }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private func beginActiveSession() {
        let s = ActivitySession(type: sessionActivity)
        s.usedGPS = gpsEnabled
        s.workoutTypeRaw = workoutType.rawValue
        snapshotSetup(into: s)

        context.insert(s)
        session = s
        startDate = Date()
        elapsed = 0
        pausedAt = nil
        pausedTotal = 0
        // Baseline the pedometer so `sessionMeters` can measure the delta when GPS
        // is off. Updates were started in `onAppear`, so by the time the user has
        // configured and started a session the reading is already live.
        motionStartMeters = motion.distanceMeters
        displayedSpeedMps = 0
        lastPaceUpdate = 0
        announcedUnits = 0
        goalAnnounced = false
        lastNudge = 0
        resetSegmentEngine()

        if gpsEnabled { startLocation(for: s) }
        if segments.contains(where: { $0.goal == .heartRate }) {
            liveHR.start()
            Task { await loadZones() }
        }

        announceStart()
        LiveActivityManager.shared.start(label: sessionActivity.rawValue,
                                         startDate: startDate ?? Date(),
                                         distanceText: unit.distanceString(sessionMeters),
                                         detail: liveDetail())

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
        ticker = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func startLocation(for s: ActivitySession) {
        if location.authorization == .notDetermined { location.requestPermission() }
        location.onPoint = { loc, estimated in
            let p = RoutePoint(
                timestamp: loc.timestamp,
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.altitude,
                horizontalAccuracy: loc.horizontalAccuracy,
                speed: max(0, loc.speed),
                isEstimated: estimated
            )
            p.session = s
            context.insert(p)
        }
        location.startTracking()
    }

    /// Snapshots the cards onto the session so history still shows what was run
    /// even if a saved template is later edited or deleted. The flat fields are
    /// filled in only for a single-card session, where they're unambiguous —
    /// that's what Stats and the exporter read.
    private func snapshotSetup(into s: ActivitySession) {
        s.customStepsJSON = ActivitySegment.encode(segments)
        s.customWorkoutName = workoutName
        guard segments.count == 1, let seg = segments.first else { return }
        switch seg.goal {
        case .distance:
            s.goalKind = "distance"; s.goalTarget = seg.endMeters
        case .time:
            s.goalKind = "time"; s.goalTarget = seg.endSeconds
        case .intervals:
            s.intervalWork = Double(seg.work)
            s.intervalRest = Double(seg.rest)
            s.intervalReps = seg.reps
        case .pace:
            s.paceTargetSecPerMeter = seg.paceTargetSecPerMeter
        case .none, .heartRate:
            break
        }
    }

    private func resetSegmentEngine() {
        segIndex = 0
        segStartElapsed = 0
        segStartMeters = 0
        segmentsDone = segments.isEmpty
        activitySeconds = [:]
        startIntervalsIfNeeded()
    }

    /// Resolves the zone bounds a heart-rate card is judged against. Uses the
    /// runner's own resting HR when Health has one — plain %max misstates the low
    /// zones badly, which is exactly where an easy-zone card lives.
    private func loadZones() async {
        let resting = await HealthService.shared.latestRestingHeartRate()
        let maxHR = HeartRateZones.maxHeartRate(
            override: maxHeartRateOverride,
            observed: nil,
            age: SuiteProfileStore.load()?.age ?? 0)
        zones = HeartRateZones.zones(maxHR: maxHR, restingHR: resting)
    }

    private func announceStart() {
        guard voiceOn else { return }
        if let first = segments.first, first.goal == .intervals {
            SpeechService.shared.speak(first.reps <= 1 ? .intervalLast
                                                       : .intervalWork(rep: 1, total: first.reps))
        } else if segments.count > 1, let first = segments.first {
            announceSegment(first)
        } else {
            SpeechService.shared.speak(.go)
        }
    }

    // MARK: - The tick

    /// Once-a-second update: timer, smoothed pace, unit marks, and the card engine.
    private func tick() {
        guard let start = startDate else { return }
        // Paused: freeze the clock. Everything keyed off `elapsed` — the card
        // engine, goals, pace nudges, unit marks — stops with it.
        guard pausedAt == nil else { return }
        elapsed = Date().timeIntervalSince(start) - pausedTotal

        if elapsed - lastPaceUpdate >= 3 {
            displayedSpeedMps = location.currentSpeedMps
            lastPaceUpdate = elapsed
        }

        if sessionMeters > 0 {
            let units = Int(sessionMeters / unitMeters)
            if units > announcedUnits {
                announcedUnits = units
                announceUnitMark(units)
            }
        }

        tickSegment()

        if Int(elapsed) % 10 == 0 { pushLiveActivity() }
    }

    /// One loop for every kind of card: intervals run their own rep machine, and
    /// everything else either finishes on its basis or gets nudged toward target.
    private func tickSegment() {
        guard let seg = currentSegment else { return }

        if seg.goal == .intervals {
            tickIntervals(seg)
            return
        }

        // No end basis means an open card — only Next moves it on.
        var finished = false
        if let end = seg.endBasis {
            finished = end == .distance ? metersInSegment >= seg.endMeters
                                        : elapsedInSegment >= seg.endSeconds
        }

        if finished {
            advanceSegment()
        } else if seg.goal == .pace {
            nudgeTowardPace(seg.paceTargetSecPerMeter)
        } else if seg.goal == .heartRate {
            nudgeTowardZone(seg.hrZone)
        }
    }

    private func startIntervalsIfNeeded() {
        guard let seg = currentSegment, seg.goal == .intervals else { return }
        intRep = 1
        intPhaseIsWork = true
        intervalsDone = false
        phaseEndsAt = elapsed + Double(max(1, seg.work))
    }

    private func tickIntervals(_ seg: ActivitySegment) {
        guard !intervalsDone, elapsed >= phaseEndsAt else { return }
        if intPhaseIsWork {
            if intRep >= seg.reps {
                intervalsDone = true
                if voiceOn { SpeechService.shared.speak(.intervalsComplete) }
                advanceSegment()
                return
            }
            intPhaseIsWork = false
            phaseEndsAt = elapsed + Double(max(0, seg.rest))
            if voiceOn { SpeechService.shared.speak(.intervalRest) }
        } else {
            intRep += 1
            intPhaseIsWork = true
            phaseEndsAt = elapsed + Double(max(1, seg.work))
            if voiceOn {
                SpeechService.shared.speak(intRep >= seg.reps ? .intervalLast
                                                              : .intervalWork(rep: intRep, total: seg.reps))
            }
        }
        pushLiveActivity()
    }

    /// Moves to the next card, banking the finished one's time against its
    /// activity so calories can be summed per activity rather than per session.
    private func advanceSegment() {
        guard !segmentsDone, segIndex < segments.count else { return }
        bankCurrentSegmentTime()

        let wasLast = segIndex + 1 >= segments.count
        segIndex += 1
        segStartElapsed = elapsed
        segStartMeters = sessionMeters
        lastNudge = elapsed          // don't nudge the instant a card starts

        guard !wasLast else {
            segmentsDone = true
            announceCompletion()
            pushLiveActivity()
            return
        }
        startIntervalsIfNeeded()
        if voiceOn { announceSegment(segments[segIndex]) }
        pushLiveActivity()
    }

    private func bankCurrentSegmentTime() {
        guard segIndex < segments.count else { return }
        let key = segments[segIndex].activity.rawValue
        activitySeconds[key, default: 0] += max(0, elapsedInSegment)
    }

    /// The last card just ended. A single distance/time card gets the goal-reached
    /// quip it always had; anything structured gets "workout complete".
    private func announceCompletion() {
        guard voiceOn, !goalAnnounced else { return }
        goalAnnounced = true
        guard segments.count == 1, let only = segments.first else {
            SpeechService.shared.speak(.workoutComplete)
            return
        }
        switch only.goal {
        case .distance:
            SpeechService.shared.speak(.goalReached(.distance, target: only.endMeters, unit: unit,
                                                    motivationIndex: Motivation.goalIndex()))
        case .time:
            SpeechService.shared.speak(.goalReached(.time, target: only.endSeconds, unit: unit,
                                                    motivationIndex: Motivation.goalIndex()))
        case .intervals:
            break   // "Intervals complete" was just spoken; don't say it twice
        default:
            SpeechService.shared.speak(.workoutComplete)
        }
    }

    // MARK: Cues

    /// Shared over/under nudging. Silent without a target, while barely moving (so
    /// a red light doesn't nag), and more often than every 25s.
    private func nudgeTowardPace(_ target: Double) {
        guard target > 0, displayedSpeedMps > 0.4, elapsed - lastNudge >= 25 else { return }
        let ratio = (1.0 / displayedSpeedMps) / target   // >1 = slower than target
        if ratio > 1.08 {
            lastNudge = elapsed
            if voiceOn { SpeechService.shared.speak(.pace(.faster)) }
        } else if ratio < 0.92 {
            lastNudge = elapsed
            if voiceOn { SpeechService.shared.speak(.pace(.slower)) }
        }
    }

    /// Same idea against a heart-rate zone. Silent with no live HR — which is the
    /// normal case without a Watch, and not something to complain about mid-run.
    private func nudgeTowardZone(_ index: Int) {
        let bpm = liveHR.bpm
        guard bpm > 0, elapsed - lastNudge >= 25,
              let zone = zones.first(where: { $0.index == index }) else { return }
        if bpm < zone.lower {
            lastNudge = elapsed
            if voiceOn { SpeechService.shared.speak(.pace(.faster)) }
        } else if bpm > zone.upper {
            lastNudge = elapsed
            if voiceOn { SpeechService.shared.speak(.pace(.slower)) }
        }
    }

    private func announceSegment(_ seg: ActivitySegment) {
        guard voiceOn else { return }
        var amount = seg.goal == .intervals ? "\(seg.reps) intervals" : ""
        if let end = seg.endBasis {
            if end == .distance {
                amount = unit.spokenDistance(seg.endMeters)
            } else {
                let m = Int((seg.endSeconds / 60).rounded())
                amount = m > 0 ? "\(m) minute\(m == 1 ? "" : "s")" : "\(Int(seg.endSeconds)) seconds"
            }
        }
        let target: String?
        switch seg.goal {
        case .pace:
            target = seg.paceTargetSecPerMeter > 0
                ? unit.spokenPace(seconds: seg.paceTargetSecPerMeter * unitMeters, meters: unitMeters)
                : nil
        case .heartRate:
            target = "zone \(seg.hrZone)"
        default:
            target = nil
        }
        SpeechService.shared.speak(.stepStart(activity: seg.activity,
                                              label: seg.label.trimmingCharacters(in: .whitespaces),
                                              amount: amount, target: target))
    }

    private func announceUnitMark(_ n: Int) {
        guard voiceOn else { return }
        SpeechService.shared.speak(.mark(unit: unit, type: liveActivity, index: n,
                                         elapsed: elapsed, meters: sessionMeters))
    }

    /// Live Activity detail line (right side of the island / lock screen).
    private func liveDetail() -> String {
        if pausedAt != nil { return "Paused" }
        guard let seg = currentSegment else { return "Workout done" }
        if seg.goal == .intervals {
            return "\(intPhaseIsWork ? "WORK" : "REST") · \(intRep)/\(seg.reps)"
        }
        let position = segments.count > 1 ? " · \(segIndex + 1)/\(segments.count)" : ""
        switch seg.goal {
        case .none:      return segments.count > 1 ? "Open\(position)" : ""
        case .distance:  return "Goal \(unit.distanceString(seg.endMeters))\(position)"
        case .time:      return "Goal \(timeString(seg.endSeconds))\(position)"
        case .pace:      return "Target \(seg.paceText(unit))\(position)"
        case .heartRate: return "Zone \(seg.hrZone)\(position)"
        case .intervals: return ""
        }
    }

    private func pushLiveActivity() {
        LiveActivityManager.shared.update(distanceText: unit.distanceString(sessionMeters),
                                          detail: liveDetail())
    }

    // MARK: - Pause / finish

    /// Pause/resume. GPS is suspended too, so standing still doesn't accrue
    /// drift-distance, and the route isn't bridged across the stop.
    private func togglePause() {
        if let since = pausedAt {
            pausedTotal += Date().timeIntervalSince(since)
            pausedAt = nil
            if session?.usedGPS == true { location.resumeTracking() }
        } else {
            pausedAt = Date()
            if session?.usedGPS == true { location.pauseTracking() }
        }
        pushLiveActivity()
    }

    private func finish() {
        // Finishing while paused: bank the final stretch so `pausedSeconds` is
        // complete and `elapsed` isn't left short.
        if let since = pausedAt {
            pausedTotal += Date().timeIntervalSince(since)
            pausedAt = nil
        }
        // The card in progress never "advanced", so bank its time here or it drops
        // out of the calorie total entirely. Running on past the last card counts
        // toward that card's activity — it's still the thing you were doing.
        if segmentsDone {
            if let last = segments.last {
                activitySeconds[last.activity.rawValue, default: 0] += max(0, elapsed - segStartElapsed)
            }
        } else {
            bankCurrentSegmentTime()
        }

        ticker?.invalidate(); ticker = nil
        location.onPoint = nil
        location.stopTracking()
        liveHR.stop()
        LiveActivityManager.shared.end()

        guard let s = session else { return }
        // Capture GPS results now (stable after stopTracking) and reset the UI
        // immediately; distance resolution may await a pedometer query.
        let end = Date()
        let seconds = elapsed
        let paused = pausedTotal
        let gpsDistance = location.distanceMeters
        let hadGap = location.hadGap
        let perActivity = activitySeconds
        session = nil
        startDate = nil
        pausedTotal = 0
        Task { await finalize(s, end: end, seconds: seconds, paused: paused,
                              gpsDistance: gpsDistance, hadGap: hadGap,
                              perActivity: perActivity) }
    }

    /// Resolves the session's distance, choosing the best available source and
    /// flagging when any of it was estimated:
    /// - GPS on, clean track → GPS distance.
    /// - GPS on, walk/run with a dropout (or total indoor loss) → fall back to the
    ///   pedometer if it measured more (it keeps counting when GPS can't).
    /// - GPS on, ride with a dropout → keep the straight-line bridge, flagged estimated.
    /// - GPS off, walk/run → pedometer distance (the expected source, not a failure).
    @MainActor
    private func finalize(_ s: ActivitySession, end: Date, seconds: Double, paused: Double,
                          gpsDistance: Double, hadGap: Bool,
                          perActivity: [String: TimeInterval]) async {
        s.endedAt = end
        s.activeSeconds = seconds
        s.pausedSeconds = paused

        // Tick off the scheduled run this session came from, if any.
        if let id = activeScheduleID {
            let match = FetchDescriptor<ScheduledRun>(
                predicate: #Predicate<ScheduledRun> { $0.id == id })
            if let sched = try? context.fetch(match).first {
                sched.isCompleted = true
                sched.completedAt = end
            }
            activeScheduleID = nil
        }

        let ped = await MotionService.shared.pedometer(from: s.startedAt, to: end)
        if s.type.pedometerDistance, let steps = ped?.steps { s.steps = steps }

        var distance = 0.0
        var estimated = false
        if s.usedGPS {
            distance = gpsDistance
            if hadGap { estimated = true }
            if s.type.pedometerDistance, let pedDist = ped?.distance, pedDist > distance {
                distance = pedDist
                if hadGap || gpsDistance == 0 { estimated = true }
            }
        } else if s.type.pedometerDistance {
            distance = ped?.distance ?? 0
        }

        s.distanceMeters = distance
        s.distanceEstimated = estimated
        s.activeEnergyKcal = kcal(perActivity: perActivity, fallbackSeconds: seconds, type: s.type)
        try? context.save()

        // Spoken recap + quip (releases the audio session when it finishes).
        if voiceOn {
            SpeechService.shared.speakFinal(.finish(type: s.type, unit: unit, meters: s.distanceMeters,
                                                    seconds: s.activeSeconds,
                                                    motivationIndex: Motivation.finishIndex()))
        } else {
            SpeechService.shared.stop()
        }

        await HealthService.shared.save(s)

        // Cache the heart-rate summary now, while the session's window is fresh.
        // No Watch simply leaves it at zero. Written after the workout save so
        // Health has the workout to attribute samples to.
        let resting = await HealthService.shared.latestRestingHeartRate()
        let maxHR = HeartRateZones.maxHeartRate(
            override: maxHeartRateOverride,
            observed: nil,
            age: SuiteProfileStore.load()?.age ?? 0)
        await HeartRateBackfill.fill(s, zones: HeartRateZones.zones(maxHR: maxHR, restingHR: resting))
    }

    /// Calories summed per card, so a run/walk workout isn't priced entirely at
    /// one activity's MET value. Falls back to the session type when no per-card
    /// time was banked.
    private func kcal(perActivity: [String: TimeInterval], fallbackSeconds: Double,
                      type: ActivityType) -> Double {
        let banked = perActivity.reduce(into: 0.0) { total, entry in
            guard let activity = ActivityType(rawValue: entry.key) else { return }
            total += HealthCalc.kcal(type: activity, minutes: entry.value / 60)
        }
        guard banked > 0 else { return HealthCalc.kcal(type: type, minutes: fallbackSeconds / 60) }
        return banked
    }

    private func timeString(_ t: TimeInterval) -> String {
        let secs = Int(t)
        if secs >= 3600 { return String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60) }
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}
