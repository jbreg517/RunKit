import SwiftUI
import SwiftData
import CoreLocation

/// Goal semantics for the distance/time completion cue.
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

struct ActivitySessionView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @AppStorage("gpsEnabled") private var gpsEnabled = true
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage("voiceAnnouncements") private var voiceOn = true
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    @State private var location = LocationService.shared
    @State private var motion = MotionService.shared
    /// Pedometer reading when the session began, so we can measure the delta.
    @State private var motionStartMeters: Double = 0

    /// Live distance for the running session. GPS when it's on; otherwise the
    /// pedometer delta since the session started — which is the *expected*
    /// source for a GPS-off walk/run, not a failure. Cycling has neither, so it
    /// reports 0 (guarded in setup: a ride can't run distance targets w/o GPS).
    private var sessionMeters: Double {
        if session?.usedGPS == true { return location.distanceMeters }
        guard selectedType.pedometerDistance else { return 0 }
        return max(0, motion.distanceMeters - motionStartMeters)
    }

    /// True when the chosen setup measures progress by distance.
    private var needsDistance: Bool {
        workoutType == .distance
            || (workoutType == .custom && steps.contains { $0.basis == .distance })
    }

    /// Cycling without GPS has no distance source at all, so a distance target
    /// could never complete. Walk/run still work via the pedometer.
    private var distanceUnavailable: Bool {
        needsDistance && !gpsEnabled && !selectedType.pedometerDistance
    }
    @State private var selectedType: ActivityType = .walk

    // Run-type setup
    @State private var workoutType: WorkoutType = .free
    @State private var goalValueText = ""          // distance or time
    @State private var intWorkText = "30"
    @State private var intRestText = "90"
    @State private var intRepsText = "8"
    @State private var paceText = ""               // "mm:ss" per unit
    @State private var showLibrary = false
    @State private var showBuilder = false
    // Custom multi-segment workout state.
    @State private var steps: [WorkoutStep] = []
    @State private var customName = ""
    @State private var stepIndex = 0
    @State private var stepStartElapsed: TimeInterval = 0
    @State private var stepStartMeters: Double = 0
    @State private var stepsDone = false
    /// Name of the picked `WorkoutRecipe`, shown until the params are edited.
    @State private var recipeName: String?
    @FocusState private var fieldFocused: Bool

    // Session lifecycle
    @State private var session: ActivitySession?
    @State private var startDate: Date?
    /// When the session was paused, and the running total of paused time.
    /// `elapsed` subtracts `pausedTotal`, so every downstream consumer — the
    /// interval state machine, goals, pace — freezes for free while paused.
    @State private var pausedAt: Date?
    @State private var pausedTotal: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var ticker: Timer?
    @State private var countdown: Int?

    // Live derived state
    @State private var mapExpanded = true
    @State private var displayedSpeedMps: Double = 0   // refreshed every 3s, smoothed
    @State private var lastPaceUpdate: TimeInterval = 0
    @State private var announcedUnits = 0
    @State private var goalAnnounced = false
    @State private var goalTarget: Double = 0          // meters or seconds

    // Live interval state
    @State private var intWork = 0.0
    @State private var intRest = 0.0
    @State private var intReps = 0
    @State private var intPhaseIsWork = true
    @State private var intRep = 1
    @State private var phaseEndsAt: TimeInterval = 0
    @State private var intervalsDone = false

    // Live pace state
    @State private var paceTargetSecPerMeter = 0.0
    @State private var lastPaceNudge: TimeInterval = 0

    private var unitMeters: Double { unit == .metric ? 1000 : 1609.344 }

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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { fieldFocused = false }
                }
            }
            .onAppear {
                consumePendingType()
                // Warm the pedometer so a GPS-off session has a live baseline to
                // measure its distance delta against.
                motion.startToday()
            }
            .onChange(of: router.pendingActivityType) { _, _ in consumePendingType() }
            .task { await HealthService.shared.requestAuthorization() }
        }
    }

    /// Applies a type requested via History's "Do Again", once, when idle.
    private func consumePendingType() {
        guard session == nil, let type = router.pendingActivityType else { return }
        selectedType = type
        router.pendingActivityType = nil
    }

    // MARK: Setup

    private var setup: some View {
        VStack(spacing: RKSpacing.lg) {
            Picker("Type", selection: $selectedType) {
                ForEach(ActivityType.allCases) { t in
                    Label(t.rawValue, systemImage: t.sfSymbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, RKSpacing.md)

            Toggle("Use GPS (route + distance)", isOn: $gpsEnabled)
                .tint(RKColor.accent)
                .padding(.horizontal, RKSpacing.md)

            if selectedType == .ride && !gpsEnabled {
                Text("Cycling distance needs GPS. Without it this is a timer only.")
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, RKSpacing.md)
            }

            workoutSetup

            if distanceUnavailable {
                warning("A \(selectedType.rawValue.lowercased()) has no way to measure distance without GPS, so distance targets would never complete. Turn GPS on, or use time-based targets.")
            } else if needsDistance && !gpsEnabled {
                warning("GPS is off — distance comes from your step counter, so it's an estimate and there'll be no route map.")
            }

            Button("Start \(selectedType.rawValue)") { startCountdown() }
                .buttonStyle(RKPrimaryButtonStyle())
                .padding(.horizontal, RKSpacing.md)
                // A custom run with no steps would start and immediately finish;
                // a distance target with no distance source would never finish.
                .disabled((workoutType == .custom && steps.isEmpty) || distanceUnavailable)
        }
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

    private var workoutSetup: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack {
                Text("Run type").font(RKFont.heading).foregroundColor(RKColor.textPrimary)
                Spacer()
                // Explicit binding rather than `.onChange`: changing the type by
                // hand drops the recipe label, but `apply(_:)` setting the type
                // must not (onChange would fire after apply and wipe the name).
                Picker("Run type", selection: Binding(
                    get: { workoutType },
                    set: { workoutType = $0; recipeName = nil }
                )) {
                    ForEach(WorkoutType.allCases) { Label($0.label, systemImage: $0.sfSymbol).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(RKColor.accent)
            }

            // Library entry point. Kept as a single row so the setup card stays
            // light — the catalog itself lives in a sheet.
            Button {
                fieldFocused = false
                showLibrary = true
            } label: {
                HStack(spacing: RKSpacing.xs) {
                    Image(systemName: "books.vertical.fill")
                    Text(recipeName ?? "Browse workouts")
                    Spacer()
                    Image(systemName: "chevron.right").font(RKFont.caption)
                }
                .font(RKFont.caption)
                .foregroundColor(recipeName == nil ? RKColor.accent : RKColor.textPrimary)
                .padding(.horizontal, RKSpacing.sm)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(RKColor.surfaceElevated)
                .cornerRadius(RKRadius.small)
            }

            switch workoutType {
            case .free:
                Text("Open session — no target.")
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
            case .distance:
                HStack {
                    TextField("0.0", text: $goalValueText)
                        .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).focused($fieldFocused)
                    Text(unit.distanceUnit).foregroundColor(RKColor.textSecondary)
                }
            case .time:
                HStack {
                    TextField("0", text: $goalValueText)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($fieldFocused)
                    Text("min").foregroundColor(RKColor.textSecondary)
                }
            case .intervals:
                intervalsSetup
            case .pace:
                HStack {
                    TextField("5:30", text: $paceText)
                        .keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder).focused($fieldFocused)
                    Text("min \(unit.paceUnit)").foregroundColor(RKColor.textSecondary)
                }
            case .custom:
                customSetup
            }
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
        .sheet(isPresented: $showLibrary) {
            WorkoutLibraryView(unit: unit) { apply($0) }
        }
        .sheet(isPresented: $showBuilder) {
            WorkoutBuilderView(unit: unit) { built, name in
                steps = built
                customName = name
                workoutType = .custom
                recipeName = name.isEmpty ? nil : name
            }
        }
    }

    /// Custom workout: a compact preview of the step list plus an edit entry point.
    private var customSetup: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            if steps.isEmpty {
                Text("Build a sequence of steps — warm-up, work at a target pace, cool-down.")
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
            } else {
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                    HStack(spacing: RKSpacing.sm) {
                        Text("\(i + 1)")
                            .font(RKFont.caption).foregroundColor(RKColor.textMuted)
                            .frame(width: 16, alignment: .trailing)
                        Image(systemName: step.kind.sfSymbol)
                            .font(RKFont.caption)
                            .foregroundColor(step.kind == .work ? RKColor.accent : RKColor.textMuted)
                        Text(step.kind.label)
                            .font(RKFont.caption).foregroundColor(RKColor.textSecondary)
                        Spacer()
                        Text(step.summary(unit))
                            .font(RKFont.caption).foregroundColor(RKColor.textPrimary)
                    }
                }
            }
            Button {
                fieldFocused = false
                showBuilder = true
            } label: {
                Label(steps.isEmpty ? "Build workout" : "Edit steps",
                      systemImage: "slider.horizontal.3")
                    .font(RKFont.caption)
            }
            .padding(.top, 2)
        }
    }

    /// Load a library workout into the setup fields. Everything a recipe sets is
    /// still editable afterwards — picking one is a starting point, not a lock.
    private func apply(_ r: WorkoutRecipe) {
        workoutType = r.workoutType
        switch r.workoutType {
        case .distance:
            let d = unit.distance(r.meters)
            goalValueText = d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)
        case .time:
            goalValueText = "\(r.minutes)"
        case .intervals:
            intWorkText = "\(r.work)"
            intRestText = "\(r.rest)"
            intRepsText = "\(r.reps)"
        case .free, .pace, .custom:
            break   // library recipes never carry pace targets or step lists
        }
        recipeName = r.name
    }

    private var intervalsSetup: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack(spacing: RKSpacing.sm) {
                fieldBox("Work", $intWorkText, "sec")
                fieldBox("Rest", $intRestText, "sec")
                fieldBox("Reps", $intRepsText, "×")
            }
            HStack(spacing: RKSpacing.sm) {
                ForEach(IntervalPreset.all) { p in
                    Button(p.name) {
                        intWorkText = "\(p.work)"; intRestText = "\(p.rest)"; intRepsText = "\(p.reps)"
                    }
                    .font(RKFont.caption)
                    .padding(.horizontal, RKSpacing.sm).padding(.vertical, 6)
                    .background(RKColor.surfaceElevated)
                    .foregroundColor(RKColor.textPrimary)
                    .cornerRadius(RKRadius.small)
                }
            }
        }
    }

    private func fieldBox(_ label: String, _ text: Binding<String>, _ suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(RKFont.caption).foregroundColor(RKColor.textMuted)
            HStack(spacing: 3) {
                TextField("0", text: text)
                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($fieldFocused)
                Text(suffix).font(RKFont.caption).foregroundColor(RKColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Live

    private var live: some View {
        VStack(spacing: RKSpacing.lg) {
            if session?.usedGPS == true { mapCard }
            if workoutType == .intervals { intervalBanner }
            if workoutType == .custom { stepBanner }

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

            if workoutType == .pace { paceBanner }
            metricsRow
            if workoutType == .distance || workoutType == .time { goalProgress }

            HStack(spacing: RKSpacing.sm) {
                Button(pausedAt == nil ? "Pause" : "Resume") { togglePause() }
                    .buttonStyle(RKSecondaryButtonStyle())
                Button("Finish") { finish() }
                    .buttonStyle(RKPrimaryButtonStyle())
            }
            .padding(.horizontal, RKSpacing.md)
        }
    }

    /// Current step, what's left of it, and what's next.
    private var stepBanner: some View {
        let step = (stepIndex < steps.count && !stepsDone) ? steps[stepIndex] : nil
        let remaining: String = {
            guard let step else { return "" }
            switch step.basis {
            case .time:
                return timeString(max(0, step.seconds - (elapsed - stepStartElapsed)))
            case .distance:
                let left = max(0, step.meters - (sessionMeters - stepStartMeters))
                return unit.distanceString(left)
            }
        }()
        return VStack(spacing: RKSpacing.xs) {
            Text(stepsDone ? "DONE" : (step?.kind.label.uppercased() ?? ""))
                .font(.system(size: 28, weight: .black))
                .foregroundColor(step?.kind == .work && !stepsDone ? RKColor.accent : RKColor.textSecondary)
            if let step, !stepsDone {
                Text("\(remaining) left  ·  Step \(stepIndex + 1) of \(steps.count)")
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
                if step.hasPaceTarget {
                    Text("Target \(step.targetText(unit).replacingOccurrences(of: "@ ", with: ""))")
                        .font(RKFont.caption).foregroundColor(RKColor.textSecondary)
                }
                if stepIndex + 1 < steps.count {
                    Text("Next: \(steps[stepIndex + 1].kind.label) · \(steps[stepIndex + 1].summary(unit))")
                        .font(RKFont.caption).foregroundColor(RKColor.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.md)
        .background((step?.kind == .work && !stepsDone) ? RKColor.accent.opacity(0.15) : RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private var intervalBanner: some View {
        let remaining = max(0, Int((phaseEndsAt - elapsed).rounded()))
        return VStack(spacing: RKSpacing.xs) {
            Text(intervalsDone ? "DONE" : (intPhaseIsWork ? "WORK" : "REST"))
                .font(.system(size: 30, weight: .black))
                .foregroundColor(intPhaseIsWork && !intervalsDone ? RKColor.accent : RKColor.textSecondary)
            if !intervalsDone {
                Text("Rep \(intRep) of \(intReps)  ·  \(remaining)s")
                    .font(RKFont.caption).foregroundColor(RKColor.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.md)
        .background((intPhaseIsWork && !intervalsDone) ? RKColor.accent.opacity(0.15) : RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private var paceBanner: some View {
        let targetPerUnit = paceTargetSecPerMeter * unitMeters
        let curPerUnit = displayedSpeedMps > 0.2 ? unitMeters / displayedSpeedMps : 0
        let state: (String, Color) = {
            guard curPerUnit > 0, targetPerUnit > 0 else { return ("—", RKColor.textMuted) }
            let r = curPerUnit / targetPerUnit
            if r > 1.08 { return ("Pick it up", RKColor.danger) }
            if r < 0.92 { return ("Ease off", RKColor.accent) }
            return ("On pace", RKColor.success)
        }()
        return VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack {
                Text("Target").font(RKFont.caption).foregroundColor(RKColor.textMuted)
                Spacer()
                Text(unit.paceString(secondsPerUnit: targetPerUnit))
                    .font(RKFont.bodyBold).foregroundColor(RKColor.textPrimary)
            }
            HStack {
                Text("You").font(RKFont.caption).foregroundColor(RKColor.textMuted)
                Spacer()
                Text(curPerUnit > 0 ? unit.paceString(secondsPerUnit: curPerUnit) : "—")
                    .font(RKFont.bodyBold).foregroundColor(state.1)
            }
            Text(state.0).font(RKFont.bodyBold).foregroundColor(state.1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
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
            metric(currentPaceString, session?.type == .ride ? "Cur Speed" : "Cur Pace")
            metric(overallPaceString, session?.type == .ride ? "Avg Speed" : "Avg Pace")
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
                Text("Goal").font(RKFont.bodyBold).foregroundColor(RKColor.textPrimary)
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

    // MARK: Derived strings

    private var currentPaceString: String {
        guard displayedSpeedMps > 0.2 else { return "--" }
        if session?.type == .ride { return unit.speedString(metersPerSecond: displayedSpeedMps) }
        return unit.paceString(secondsPerUnit: unitMeters / displayedSpeedMps)
    }

    private var overallPaceString: String {
        let d = sessionMeters
        if session?.type == .ride { return unit.speedString(seconds: elapsed, meters: d) }
        return unit.paceString(seconds: elapsed, meters: d)
    }

    private func goalFraction() -> Double {
        guard goalTarget > 0 else { return 0 }
        let value = workoutType == .distance ? sessionMeters : elapsed
        return min(1, value / goalTarget)
    }

    private func goalLabel() -> String {
        switch workoutType {
        case .distance: return "\(unit.distanceString(sessionMeters)) / \(unit.distanceString(goalTarget))"
        case .time:     return "\(timeString(elapsed)) / \(timeString(goalTarget))"
        default:        return ""
        }
    }

    // MARK: Lifecycle

    /// 3-2-1 visual countdown, then the session begins.
    private func startCountdown() {
        fieldFocused = false
        withAnimation { countdown = 3 }
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            guard let c = countdown else { timer.invalidate(); return }
            if c <= 1 {
                timer.invalidate()
                withAnimation { countdown = nil }
                // Intervals announce "Work! Rep 1" themselves, so skip the generic "Go".
                if voiceOn && workoutType != .intervals { SpeechService.shared.speak(.go) }
                beginActiveSession()
            } else {
                withAnimation { countdown = c - 1 }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private func beginActiveSession() {
        let s = ActivitySession(type: selectedType)
        s.usedGPS = gpsEnabled
        s.workoutTypeRaw = workoutType.rawValue
        resolveWorkoutParams(into: s)

        context.insert(s)
        session = s
        startDate = Date()
        elapsed = 0
        pausedAt = nil
        pausedTotal = 0
        // Baseline the pedometer so `sessionMeters` can measure the delta when
        // GPS is off. Updates were started in `onAppear`, so by the time the user
        // has configured and started a session the reading is already live.
        motionStartMeters = motion.distanceMeters
        displayedSpeedMps = 0
        lastPaceUpdate = 0
        announcedUnits = 0
        goalAnnounced = false
        lastPaceNudge = 0

        if gpsEnabled {
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

        if workoutType == .intervals, voiceOn {
            SpeechService.shared.speak(intReps <= 1 ? .intervalLast : .intervalWork(rep: 1, total: intReps))
        }
        if workoutType == .custom, let first = steps.first {
            announceStep(first)
        }

        LiveActivityManager.shared.start(label: selectedType.rawValue, startDate: startDate ?? Date(),
                                         distanceText: unit.distanceString(sessionMeters),
                                         detail: liveDetail())

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
        ticker = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Reads the setup text fields into `@State` + the session's stored params.
    private func resolveWorkoutParams(into s: ActivitySession) {
        goalTarget = 0
        switch workoutType {
        case .free:
            break
        case .distance:
            goalTarget = unit.meters(fromDisplay: goalValueText) ?? 0
            s.goalKind = "distance"; s.goalTarget = goalTarget
        case .time:
            goalTarget = (Double(goalValueText) ?? 0) * 60
            s.goalKind = "time"; s.goalTarget = goalTarget
        case .intervals:
            intWork = Double(max(1, Int(intWorkText) ?? 0))
            intRest = Double(max(0, Int(intRestText) ?? 0))
            intReps = max(1, Int(intRepsText) ?? 1)
            intRep = 1; intPhaseIsWork = true; intervalsDone = false; phaseEndsAt = intWork
            s.intervalWork = intWork; s.intervalRest = intRest; s.intervalReps = intReps
        case .pace:
            paceTargetSecPerMeter = parsePace(paceText)
            s.paceTargetSecPerMeter = paceTargetSecPerMeter
        case .custom:
            stepIndex = 0
            stepStartElapsed = 0
            stepStartMeters = 0
            stepsDone = steps.isEmpty
            // Snapshot the steps onto the session so history still shows what was
            // run even if the saved workout is later edited or deleted.
            s.customStepsJSON = WorkoutStep.encode(steps)
            s.customWorkoutName = customName
        }
    }

    /// "mm:ss" (or plain minutes) per unit → seconds per meter.
    private func parsePace(_ s: String) -> Double {
        let parts = s.split(separator: ":")
        var perUnit = 0.0
        if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) {
            perUnit = m * 60 + sec
        } else if let m = Double(s.replacingOccurrences(of: ",", with: ".")) {
            perUnit = m * 60
        }
        return perUnit > 0 ? perUnit / unitMeters : 0
    }

    /// Once-a-second update: timer, smoothed pace, unit marks, and run-type logic.
    private func tick() {
        guard let start = startDate else { return }
        // Paused: freeze the clock. Everything keyed off `elapsed` (intervals,
        // goals, pace nudges, unit marks) stops with it.
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

        switch workoutType {
        case .intervals: tickIntervals()
        case .pace:      tickPace()
        case .custom:    tickCustom()
        case .distance, .time:
            if !goalAnnounced, goalTarget > 0, goalFraction() >= 1 {
                goalAnnounced = true
                if voiceOn {
                    let gk: GoalKind = workoutType == .time ? .time : .distance
                    SpeechService.shared.speak(.goalReached(gk, target: goalTarget, unit: unit,
                                                            motivationIndex: Motivation.goalIndex()))
                }
            }
        case .free:
            break
        }

        if Int(elapsed) % 10 == 0 { pushLiveActivity() }
    }

    private func tickIntervals() {
        guard !intervalsDone, elapsed >= phaseEndsAt else { return }
        if intPhaseIsWork {
            if intRep >= intReps {
                intervalsDone = true
                if voiceOn { SpeechService.shared.speak(.intervalsComplete) }
                pushLiveActivity()
                return
            }
            intPhaseIsWork = false
            phaseEndsAt = elapsed + intRest
            if voiceOn { SpeechService.shared.speak(.intervalRest) }
        } else {
            intRep += 1
            intPhaseIsWork = true
            phaseEndsAt = elapsed + intWork
            if voiceOn {
                SpeechService.shared.speak(intRep >= intReps ? .intervalLast
                                                             : .intervalWork(rep: intRep, total: intReps))
            }
        }
        pushLiveActivity()
    }

    /// Live Activity detail line (right side of the island / lock screen).
    private func liveDetail() -> String {
        if pausedAt != nil { return "Paused" }
        switch workoutType {
        case .custom:
            guard !stepsDone, stepIndex < steps.count else { return "Workout done" }
            return "\(steps[stepIndex].kind.label) · \(stepIndex + 1)/\(steps.count)"
        case .intervals:
            return intervalsDone ? "Intervals done" : "\(intPhaseIsWork ? "WORK" : "REST") · \(intRep)/\(intReps)"
        case .pace:
            return "Target \(unit.paceString(secondsPerUnit: paceTargetSecPerMeter * unitMeters))"
        case .distance:
            return goalTarget > 0 ? "Goal \(unit.distanceString(goalTarget))" : ""
        case .time:
            return goalTarget > 0 ? "Goal \(timeString(goalTarget))" : ""
        case .free:
            return ""
        }
    }

    private func pushLiveActivity() {
        LiveActivityManager.shared.update(distanceText: unit.distanceString(sessionMeters),
                                          detail: liveDetail())
    }

    private func tickPace() {
        nudgeToward(paceTargetSecPerMeter)
    }

    /// Shared over/under-pace nudging. Silent without a target, while barely
    /// moving (so a red light doesn't nag), and more often than every 25s.
    private func nudgeToward(_ target: Double) {
        guard target > 0, displayedSpeedMps > 0.4,
              elapsed - lastPaceNudge >= 25 else { return }
        let ratio = (1.0 / displayedSpeedMps) / target   // >1 = slower than target
        if ratio > 1.08 {
            lastPaceNudge = elapsed
            if voiceOn { SpeechService.shared.speak(.pace(.faster)) }
        } else if ratio < 0.92 {
            lastPaceNudge = elapsed
            if voiceOn { SpeechService.shared.speak(.pace(.slower)) }
        }
    }

    /// Advances the custom step sequence. Each step ends on its own basis —
    /// elapsed time or distance covered since the step began — and carries its
    /// own optional pace target.
    private func tickCustom() {
        guard !stepsDone, stepIndex < steps.count else { return }
        let step = steps[stepIndex]

        let finished: Bool
        switch step.basis {
        case .time:     finished = elapsed - stepStartElapsed >= step.seconds
        case .distance: finished = sessionMeters - stepStartMeters >= step.meters
        }

        if finished {
            advanceStep()
        } else {
            nudgeToward(step.paceTargetSecPerMeter)
        }
    }

    private func advanceStep() {
        stepIndex += 1
        stepStartElapsed = elapsed
        stepStartMeters = sessionMeters
        lastPaceNudge = elapsed          // don't nudge the instant a step starts

        guard stepIndex < steps.count else {
            stepsDone = true
            if voiceOn { SpeechService.shared.speak(.workoutComplete) }
            pushLiveActivity()
            return
        }
        announceStep(steps[stepIndex])
        pushLiveActivity()
    }

    private func announceStep(_ step: WorkoutStep) {
        guard voiceOn else { return }
        let amount: String
        switch step.basis {
        case .time:
            let m = Int((step.seconds / 60).rounded())
            amount = m > 0 ? "\(m) minute\(m == 1 ? "" : "s")" : "\(Int(step.seconds)) seconds"
        case .distance:
            amount = unit.spokenDistance(step.meters)
        }
        let target = step.hasPaceTarget
            ? unit.spokenPace(seconds: step.paceTargetSecPerMeter * unitMeters, meters: unitMeters)
            : nil
        SpeechService.shared.speak(.stepStart(kind: step.kind, amount: amount, target: target))
    }

    private func announceUnitMark(_ n: Int) {
        guard voiceOn, let type = session?.type else { return }
        SpeechService.shared.speak(.mark(unit: unit, type: type, index: n,
                                         elapsed: elapsed, meters: sessionMeters))
    }

    /// Pause/resume. GPS is suspended too, so standing still doesn't accrue
    /// drift-distance, and the route isn't bridged across the stop.
    private func togglePause() {
        if let since = pausedAt {
            pausedTotal += Date().timeIntervalSince(since)
            pausedAt = nil
            if session?.usedGPS == true { location.resumeTracking() }
            pushLiveActivity()
        } else {
            pausedAt = Date()
            if session?.usedGPS == true { location.pauseTracking() }
            pushLiveActivity()
        }
    }

    private func finish() {
        // Finishing while paused: bank the final stretch so `pausedSeconds` is
        // complete and `elapsed` isn't left short.
        if let since = pausedAt {
            pausedTotal += Date().timeIntervalSince(since)
            pausedAt = nil
        }
        ticker?.invalidate(); ticker = nil
        location.onPoint = nil
        location.stopTracking()
        LiveActivityManager.shared.end()

        guard let s = session else { return }
        // Capture GPS results now (stable after stopTracking) and reset the UI
        // immediately; distance resolution may await a pedometer query.
        let end = Date()
        let seconds = elapsed
        let paused = pausedTotal
        let gpsDistance = location.distanceMeters
        let hadGap = location.hadGap
        session = nil
        startDate = nil
        pausedTotal = 0
        Task { await finalize(s, end: end, seconds: seconds, paused: paused,
                              gpsDistance: gpsDistance, hadGap: hadGap) }
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
                          gpsDistance: Double, hadGap: Bool) async {
        s.endedAt = end
        s.activeSeconds = seconds
        s.pausedSeconds = paused

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
        s.activeEnergyKcal = HealthCalc.kcal(type: s.type, minutes: seconds / 60)
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
    }

    private func timeString(_ t: TimeInterval) -> String {
        let secs = Int(t)
        if secs >= 3600 { return String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60) }
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}
