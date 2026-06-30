import SwiftUI
import SwiftData
import CoreLocation

/// Session goal chosen in setup.
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

    // Goal setup
    @State private var goalKind: GoalKind = .none
    @State private var goalValueText = ""
    @FocusState private var goalFieldFocused: Bool

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
                    .onTapGesture { goalFieldFocused = false }
                }
                .scrollDismissesKeyboard(.interactively)
                if let c = countdown { countdownOverlay(c) }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { goalFieldFocused = false }
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

            goalSetup

            Button("Start \(selectedType.rawValue)") { startCountdown() }
                .buttonStyle(RKPrimaryButtonStyle())
                .padding(.horizontal, RKSpacing.md)
        }
    }

    private var goalSetup: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            Text("Goal").font(RKFont.heading).foregroundColor(RKColor.textPrimary)
            Picker("Goal", selection: $goalKind) {
                ForEach(GoalKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if goalKind == .distance {
                HStack {
                    TextField("0.0", text: $goalValueText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .focused($goalFieldFocused)
                    Text(unit.distanceUnit).foregroundColor(RKColor.textSecondary)
                }
            } else if goalKind == .time {
                HStack {
                    TextField("0", text: $goalValueText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .focused($goalFieldFocused)
                    Text("min").foregroundColor(RKColor.textSecondary)
                }
            }
        }
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    // MARK: Live

    private var live: some View {
        VStack(spacing: RKSpacing.lg) {
            if session?.usedGPS == true { mapCard }

            Text(timeString(elapsed))
                .font(.system(size: 60, weight: .black, design: .monospaced))
                .foregroundColor(RKColor.textPrimary)
                .contentTransition(.numericText())

            metricsRow
            if goalKind != .none { goalProgress }

            Button("Finish") { finish() }
                .buttonStyle(RKPrimaryButtonStyle())
                .padding(.horizontal, RKSpacing.md)
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
        let value = goalKind == .distance ? location.distanceMeters : elapsed
        return min(1, value / goalTarget)
    }

    private func goalLabel() -> String {
        switch goalKind {
        case .distance: return "\(unit.distanceString(location.distanceMeters)) / \(unit.distanceString(goalTarget))"
        case .time:     return "\(timeString(elapsed)) / \(timeString(goalTarget))"
        case .none:     return ""
        }
    }

    // MARK: Lifecycle

    /// 3-2-1 visual countdown, then the session begins.
    private func startCountdown() {
        goalFieldFocused = false
        withAnimation { countdown = 3 }
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            guard let c = countdown else { timer.invalidate(); return }
            if c <= 1 {
                timer.invalidate()
                withAnimation { countdown = nil }
                if voiceOn { SpeechService.shared.speak(.go) }
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
        goalTarget = resolvedGoalTarget()
        s.goalKind = goalKind == .none ? nil : goalKind.rawValue
        s.goalTarget = goalTarget
        context.insert(s)
        session = s
        startDate = Date()
        elapsed = 0
        displayedSpeedMps = 0
        lastPaceUpdate = 0
        announcedUnits = 0
        goalAnnounced = false

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

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
        ticker = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func resolvedGoalTarget() -> Double {
        switch goalKind {
        case .distance: return unit.meters(fromDisplay: goalValueText) ?? 0
        case .time:     return (Double(goalValueText) ?? 0) * 60
        case .none:     return 0
        }
    }

    /// Once-a-second update: timer, smoothed current pace (every 3s), voice marks.
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

        if !goalAnnounced, goalTarget > 0, goalFraction() >= 1 {
            goalAnnounced = true
            if voiceOn {
                SpeechService.shared.speak(.goalReached(goalKind, target: goalTarget, unit: unit,
                                                        motivationIndex: Motivation.goalIndex()))
            }
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

        // Spoken recap + motivation (releases the audio session when it finishes).
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
