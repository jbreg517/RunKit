import SwiftUI
import SwiftData

struct ActivitySessionView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("gpsEnabled") private var gpsEnabled = true
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
        }
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
                Text(String(format: "%.2f km", location.distanceMeters / 1000))
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
            location.onPoint = { loc in
                let p = RoutePoint(
                    timestamp: loc.timestamp,
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    altitude: loc.altitude,
                    horizontalAccuracy: loc.horizontalAccuracy,
                    speed: max(0, loc.speed)
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

        if let s = session {
            s.endedAt = Date()
            s.activeSeconds = elapsed
            s.distanceMeters = s.usedGPS ? location.distanceMeters : 0
            s.activeEnergyKcal = HealthCalc.kcal(type: s.type, minutes: elapsed / 60)
            try? context.save()
            Task { await HealthService.shared.save(s) }
        }
        session = nil
        startDate = nil
    }

    private func timeString(_ t: TimeInterval) -> String {
        let secs = Int(t)
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}
