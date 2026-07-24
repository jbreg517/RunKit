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
    @State private var selectedType: ActivityType = .walk

    // Run-type setup
    @State private var workoutType: WorkoutType = .free
    @State private var goalValueText = ""          // distance or time
    @State private var intWorkText = "30"
    @State private var intRestText = "90"
    @State private var intRepsText = "8"
    @State private var paceText = ""               // "mm:ss" per unit
    @FocusState private var fieldFocused: Bool

    // Session lifecycle
    @State private var session: ActivitySession?
    @State private var startDate: Date?
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
            .onAppear { consumePendingType() }
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

            Button("Start \(selectedType.rawValue)") { startCountdown() }
                .buttonStyle(RKPrimaryButtonStyle())
                .padding(.horizontal, RKSpacing.md)
        }
    }

    private var workoutSetup: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            HStack {
                Text("Run type").font(RKFont.heading).foregroundColor(RKColor.textPrimary)
                Spacer()
                Picker("Run type", selection: $workoutType) {
                    ForEach(WorkoutType.allCases) { Label($0.label, systemImage: $0.sfSymbol).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(RKColor.accent)
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
            }
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
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

            Text(timeString(elapsed))
                .font(.system(size: 60, weight: .black, design: .monospaced))
                .foregroundColor(RKColor.textPrimary)
                .contentTransition(.numericText())

            if workoutType == .pace { paceBanner }
            metricsRow
            if workoutType == .distance || workoutType == .time { goalProgress }

            Button("Finish") { finish() }
                .buttonStyle(RKPrimaryButtonStyle())
                .padding(.horizontal, RKSpacing.md)
        }
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
            metric(unit.distanceString(location.distanceMeters), "Distance")
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
        let d = location.distanceMeters
        if session?.type == .ride { return unit.speedString(seconds: elapsed, meters: d) }
        return unit.paceString(seconds: elapsed, meters: d)
    }

    private func goalFraction() -> Double {
        guard goalTarget > 0 else { return 0 }
        let value = workoutType == .distance ? location.distanceMeters : elapsed
        return min(1, value / goalTarget)
    }

    private func goalLabel() -> String {
        switch workoutType {
        case .distance: return "\(unit.distanceString(location.distanceMeters)) / \(unit.distanceString(goalTarget))"
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
        elapsed = Date().timeIntervalSince(start)

        if elapsed - lastPaceUpdate >= 3 {
            displayedSpeedMps = location.currentSpeedMps
            lastPaceUpdate = elapsed
        }

        if location.distanceMeters > 0 {
            let units = Int(location.distanceMeters / unitMeters)
            if units > announcedUnits {
                announcedUnits = units
                announceUnitMark(units)
            }
        }

        switch workoutType {
        case .intervals: tickIntervals()
        case .pace:      tickPace()
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
    }

    private func tickIntervals() {
        guard !intervalsDone, elapsed >= phaseEndsAt else { return }
        if intPhaseIsWork {
            if intRep >= intReps {
                intervalsDone = true
                if voiceOn { SpeechService.shared.speak(.intervalsComplete) }
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
    }

    private func tickPace() {
        guard paceTargetSecPerMeter > 0, displayedSpeedMps > 0.4,
              elapsed - lastPaceNudge >= 25 else { return }
        let ratio = (1.0 / displayedSpeedMps) / paceTargetSecPerMeter   // >1 = slower than target
        if ratio > 1.08 {
            lastPaceNudge = elapsed
            if voiceOn { SpeechService.shared.speak(.pace(.faster)) }
        } else if ratio < 0.92 {
            lastPaceNudge = elapsed
            if voiceOn { SpeechService.shared.speak(.pace(.slower)) }
        }
    }

    private func announceUnitMark(_ n: Int) {
        guard voiceOn, let type = session?.type else { return }
        SpeechService.shared.speak(.mark(unit: unit, type: type, index: n,
                                         elapsed: elapsed, meters: location.distanceMeters))
    }

    private func finish() {
        ticker?.invalidate(); ticker = nil
        location.onPoint = nil
        location.stopTracking()

        guard let s = session else { return }
        // Capture GPS results now (stable after stopTracking) and reset the UI
        // immediately; distance resolution may await a pedometer query.
        let end = Date()
        let seconds = elapsed
        let gpsDistance = location.distanceMeters
        let hadGap = location.hadGap
        session = nil
        startDate = nil
        Task { await finalize(s, end: end, seconds: seconds, gpsDistance: gpsDistance, hadGap: hadGap) }
    }

    /// Resolves the session's distance, choosing the best available source and
    /// flagging when any of it was estimated:
    /// - GPS on, clean track → GPS distance.
    /// - GPS on, walk/run with a dropout (or total indoor loss) → fall back to the
    ///   pedometer if it measured more (it keeps counting when GPS can't).
    /// - GPS on, ride with a dropout → keep the straight-line bridge, flagged estimated.
    /// - GPS off, walk/run → pedometer distance (the expected source, not a failure).
    @MainActor
    private func finalize(_ s: ActivitySession, end: Date, seconds: Double,
                          gpsDistance: Double, hadGap: Bool) async {
        s.endedAt = end
        s.activeSeconds = seconds

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
