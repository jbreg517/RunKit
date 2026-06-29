import SwiftUI
import SwiftData

struct ActivitySessionView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("gpsEnabled") private var gpsEnabled = true
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    @Environment(AppRouter.self) private var router
    @State private var location = LocationService.shared

    @State private var selectedType: ActivityType = .walk
    @State private var session: ActivitySession?
    @State private var elapsed: TimeInterval = 0
    @State private var startDate: Date?
    @State private var ticker: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: RKSpacing.lg) {
                if session == nil { setup } else { live }
            }
            .padding(.vertical, RKSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Activity")
            .background(RKColor.background.ignoresSafeArea())
            .onAppear { consumePendingType() }
            .onChange(of: router.pendingActivityType) { _, _ in consumePendingType() }
            .task { await HealthService.shared.requestAuthorization() }
        }
    }

    /// Applies a type requested via History's "Do Again", once, when no session
    /// is in progress.
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
                    .padding(.horizontal, RKSpacing.md)
            }

            Button("Start \(selectedType.rawValue)") { start() }
                .buttonStyle(RKPrimaryButtonStyle())
                .padding(.horizontal, RKSpacing.md)
        }
    }

    // MARK: Live

    private var live: some View {
        VStack(spacing: RKSpacing.lg) {
            Image(systemName: selectedType.sfSymbol)
                .font(.system(size: 40))
                .foregroundColor(RKColor.accent)
            Text(timeString(elapsed))
                .font(.system(size: 64, weight: .black, design: .monospaced))
                .foregroundColor(RKColor.textPrimary)
                .contentTransition(.numericText())
            if session?.usedGPS == true {
                Text(unit.distanceString(location.distanceMeters))
                    .font(RKFont.heading)
                    .foregroundColor(RKColor.accent)
            }
            Button("Finish") { finish() }
                .buttonStyle(RKPrimaryButtonStyle())
                .padding(.horizontal, RKSpacing.md)
        }
    }

    // MARK: Actions

    private func start() {
        let s = ActivitySession(type: selectedType)
        s.usedGPS = gpsEnabled
        context.insert(s)
        session = s
        startDate = Date()
        elapsed = 0

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

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if let start = startDate { elapsed = Date().timeIntervalSince(start) }
        }
        ticker = t
        RunLoop.main.add(t, forMode: .common)
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
        await HealthService.shared.save(s)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let secs = Int(t)
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}
