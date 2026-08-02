import Foundation
import HealthKit
import CoreLocation
import Observation
import WatchKit

/// Records a run on the wrist and runs the card engine while it does.
///
/// The metrics come from `HKLiveWorkoutBuilder` rather than being computed here:
/// the watch fuses GPS with wrist motion far better than a raw `CLLocation` sum,
/// and it is the only source of real-time heart rate. Location is still collected,
/// but only to draw the route — never for distance.
///
/// The card engine is a faithful port of `ActivitySessionView`'s: same termination
/// rules, same interval machine, same 25-second nudge floor. Cues are haptic rather
/// than spoken, which on a wrist works with headphones off and costs no bundle size.
@Observable
final class WatchWorkoutController: NSObject {
    static let shared = WatchWorkoutController()

    enum Phase: Equatable { case idle, running, paused, ending, saved, failed(String) }

    /// What the run came to. Held after `phase` becomes `.saved` so the summary
    /// screen has something to show — the live properties are reset by the next
    /// `start`, and a run that simply vanishes when you finish it is the single
    /// most annoying thing a tracker can do.
    struct Summary: Equatable {
        var activity: ActivityType = .run
        var seconds: TimeInterval = 0
        var meters: Double = 0
        var kcal: Double = 0
        var avgBpm: Double = 0
        var maxBpm: Double = 0
    }

    // MARK: Published state

    private(set) var phase: Phase = .idle
    private(set) var summary: Summary?
    /// Active seconds — paused time excluded, exactly like the phone.
    private(set) var elapsed: TimeInterval = 0
    private(set) var distanceMeters: Double = 0
    private(set) var bpm: Double = 0
    private(set) var kcal: Double = 0
    /// Smoothed every 3s, so pace doesn't flicker on GPS jitter.
    private(set) var speedMps: Double = 0

    private(set) var segments: [ActivitySegment] = []
    private(set) var segIndex = 0
    private(set) var segmentsDone = false
    private(set) var intRep = 1
    private(set) var intPhaseIsWork = true

    var currentSegment: ActivitySegment? {
        segIndex < segments.count ? segments[segIndex] : nil
    }
    var unit: UnitSystem { WatchStore.shared.unit }

    // MARK: Private

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private let locationManager = CLLocationManager()

    private var ticker: Timer?
    private var startDate: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    private var segStartElapsed: TimeInterval = 0
    private var segStartMeters: Double = 0
    private var phaseEndsAt: TimeInterval = 0
    private var intervalsDone = false
    private var lastNudge: TimeInterval = 0
    private var lastPaceUpdate: TimeInterval = 0
    /// Whole km/mi marks already signalled, so each split buzzes exactly once.
    private var markedUnits = 0
    private var latestSpeed: Double = 0

    private var maxBpm: Double = 0
    /// Accumulated independently of the zone buckets. Zones need a synced max HR;
    /// heart rate itself does not, and losing the whole HR summary because the phone
    /// never sent one would be a silly way to throw away real data.
    private var bpmSum: Double = 0
    private var bpmSamples: Int = 0
    private var zoneSeconds = [Double](repeating: 0, count: 5)
    private var route: [WatchSessionPayload.Point] = []
    private var pendingLocations: [CLLocation] = []
    private var usedGPS = false

    private var sourceItem: WatchMenu.Item?

    private var elapsedInSegment: TimeInterval { elapsed - segStartElapsed }
    private var metersInSegment: Double { distanceMeters - segStartMeters }

    // MARK: - Authorization

    /// Requested up front rather than at Start: a permission sheet appearing over a
    /// run that has already begun costs the user the first minute of it.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling)
        ]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling)
        ]
        try? await healthStore.requestAuthorization(toShare: share, read: read)
    }

    // MARK: - Start

    func start(_ item: WatchMenu.Item) {
        // Anything but a live session may start a new one — including after a
        // failure, which otherwise locks the app out of recording until relaunch.
        guard phase != .running, phase != .paused, phase != .ending,
              HKHealthStore.isHealthDataAvailable() else { return }
        reset()
        sourceItem = item
        segments = item.segments.isEmpty ? ActivitySegment.starter : item.segments

        let activity = item.activity
        let config = HKWorkoutConfiguration()
        config.activityType = Self.hkActivity(activity)
        config.locationType = .outdoor

        do {
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                   workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())

            let now = Date()
            startDate = now
            s.startActivity(with: now)
            b.beginCollection(withStart: now) { _, _ in }
        } catch {
            phase = .failed("Couldn’t start the workout")
            return
        }

        startLocation()
        phase = .running
        startIntervalsIfNeeded()
        WKInterfaceDevice.current().play(.start)
        startTicker()
    }

    private func reset() {
        elapsed = 0; distanceMeters = 0; bpm = 0; kcal = 0; speedMps = 0
        segIndex = 0; segmentsDone = false; intRep = 1; intPhaseIsWork = true
        segStartElapsed = 0; segStartMeters = 0; phaseEndsAt = 0
        intervalsDone = false; lastNudge = 0; lastPaceUpdate = 0; latestSpeed = 0
        markedUnits = 0; summary = nil
        maxBpm = 0; bpmSum = 0; bpmSamples = 0
        zoneSeconds = [Double](repeating: 0, count: 5)
        route = []; pendingLocations = []; usedGPS = false
        pausedAt = nil; pausedTotal = 0; startDate = nil
    }

    // MARK: - Controls

    func pause() {
        guard phase == .running else { return }
        pausedAt = Date()
        phase = .paused
        session?.pause()
        WKInterfaceDevice.current().play(.stop)
    }

    func resume() {
        guard phase == .paused, let since = pausedAt else { return }
        pausedTotal += Date().timeIntervalSince(since)
        pausedAt = nil
        phase = .running
        session?.resume()
        WKInterfaceDevice.current().play(.start)
    }

    /// Skip to the next card. The only way past an open card, and the reason an
    /// open card exists at all.
    func next() {
        guard phase == .running || phase == .paused, !segmentsDone else { return }
        advanceSegment()
    }

    func end() {
        guard phase == .running || phase == .paused else { return }
        phase = .ending
        ticker?.invalidate()
        ticker = nil
        stopLocation()
        session?.end()
    }

    // MARK: - The tick

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common mode so the timer keeps firing while the user scrolls the crown.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    @MainActor
    private func tick() {
        guard let start = startDate, phase == .running else { return }
        elapsed = Date().timeIntervalSince(start) - pausedTotal

        if elapsed - lastPaceUpdate >= 3 {
            speedMps = latestSpeed
            lastPaceUpdate = elapsed
        }

        // Split marks. The phone speaks these ("3 kilometres, 18 minutes"); on the
        // wrist a distinct light tap is the equivalent — it reads at a glance with
        // the metrics page already showing the numbers, and needs no headphones.
        if distanceMeters > 0 {
            let units = Int(distanceMeters / unit.metersPerUnit)
            if units > markedUnits {
                markedUnits = units
                WKInterfaceDevice.current().play(.click)
            }
        }

        // One second in whatever zone the wrist is reading right now. Sampling at a
        // fixed rate sidesteps the gap-attribution problem the phone has to solve
        // when it re-reads irregular HealthKit samples after the fact.
        if bpm > 0 {
            bpmSum += bpm
            bpmSamples += 1
            let zones = WatchStore.shared.menu.zones
            if !zones.isEmpty {
                zoneSeconds[HeartRateZones.zoneIndex(for: bpm, zones: zones)] += 1
            }
        }

        tickSegment()
        flushLocations()
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
                advanceSegment()
                return
            }
            intPhaseIsWork = false
            phaseEndsAt = elapsed + Double(max(0, seg.rest))
            WKInterfaceDevice.current().play(.stop)
        } else {
            intRep += 1
            intPhaseIsWork = true
            phaseEndsAt = elapsed + Double(max(1, seg.work))
            WKInterfaceDevice.current().play(.start)
        }
    }

    private func advanceSegment() {
        guard !segmentsDone, segIndex < segments.count else { return }

        let wasLast = segIndex + 1 >= segments.count
        segIndex += 1
        segStartElapsed = elapsed
        segStartMeters = distanceMeters
        lastNudge = elapsed          // don't nudge the instant a card starts

        guard !wasLast else {
            segmentsDone = true
            // Deliberately not auto-ending: the runner may want a cool-down, and
            // stopping the recording out from under them is not recoverable.
            WKInterfaceDevice.current().play(.success)
            return
        }
        startIntervalsIfNeeded()
        WKInterfaceDevice.current().play(.notification)
    }

    // MARK: Cues

    /// Silent without a target, while barely moving (so a red light doesn't nag),
    /// and more often than every 25s — the same floor the phone uses.
    private func nudgeTowardPace(_ target: Double) {
        guard target > 0, speedMps > 0.4, elapsed - lastNudge >= 25 else { return }
        let ratio = (1.0 / speedMps) / target   // >1 = slower than target
        if ratio > 1.08 {
            lastNudge = elapsed
            WKInterfaceDevice.current().play(.directionUp)
        } else if ratio < 0.92 {
            lastNudge = elapsed
            WKInterfaceDevice.current().play(.directionDown)
        }
    }

    /// Same idea against a heart-rate zone. Silent with no live HR and silent when
    /// the phone has never synced a max HR — an unconfigured zone is not a reason to
    /// buzz someone's wrist every 25 seconds.
    private func nudgeTowardZone(_ index: Int) {
        guard bpm > 0, elapsed - lastNudge >= 25 else { return }
        let zones = WatchStore.shared.menu.zones
        guard let zone = zones.first(where: { $0.index == index }) else { return }
        if bpm < zone.lower {
            lastNudge = elapsed
            WKInterfaceDevice.current().play(.directionUp)
        } else if bpm > zone.upper {
            lastNudge = elapsed
            WKInterfaceDevice.current().play(.directionDown)
        }
    }

    // MARK: - Location (route only)

    private func startLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .fitness
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        // `allowsBackgroundLocationUpdates` is deliberately NOT set. It requires the
        // `location` background mode, which can't coexist with `workout-processing`
        // — and it isn't needed: the live workout session keeps the app out of
        // suspension, so fixes keep arriving with the wrist down. Setting it without
        // the matching mode is also how you get a CoreLocation exception at runtime.
    }

    private func stopLocation() {
        locationManager.stopUpdatingLocation()
    }

    /// Hands buffered fixes to the route builder once a second rather than per
    /// callback — `insertRouteData` is a disk write, and the GPS can deliver several
    /// fixes in a burst after a tunnel.
    private func flushLocations() {
        guard !pendingLocations.isEmpty else { return }
        let batch = pendingLocations
        pendingLocations.removeAll()
        routeBuilder?.insertRouteData(batch) { _, _ in }
    }

    // MARK: - Finishing

    private func finish() {
        guard let builder, let start = startDate else {
            phase = .failed("Nothing to save")
            return
        }
        let end = Date()
        flushLocations()

        builder.endCollection(withEnd: end) { [weak self] _, _ in
            builder.finishWorkout { workout, _ in
                // The route attaches to the saved workout, so it has to wait for the
                // workout to exist. A failure here loses the map, not the run.
                if let workout {
                    self?.routeBuilder?.finishRoute(with: workout, metadata: nil) { _, _ in }
                }
                Task { @MainActor in
                    self?.deliver(start: start, end: end)
                }
            }
        }
    }

    @MainActor
    private func deliver(start: Date, end: Date) {
        var payload = WatchSessionPayload()
        payload.activityRaw = (sourceItem?.activity ?? .run).rawValue
        payload.startedAt = start
        payload.endedAt = end
        payload.activeSeconds = elapsed
        payload.pausedSeconds = pausedTotal
        payload.distanceMeters = distanceMeters
        payload.activeEnergyKcal = kcal
        payload.usedGPS = usedGPS
        payload.avgHeartRateBpm = averageBpm()
        payload.maxHeartRateBpm = maxBpm
        payload.hrZoneSeconds = zoneSeconds
        payload.segments = segments
        payload.workoutName = sourceItem?.name ?? ""
        // Only a scheduled run carries an id the phone should tick off. A prebuilt
        // or saved workout's id refers to a template, which must not be marked done.
        if sourceItem?.source == .scheduled { payload.scheduleID = sourceItem?.referenceID }
        payload.route = route

        WatchStore.shared.send(payload)
        summary = Summary(activity: payload.activity,
                          seconds: elapsed,
                          meters: distanceMeters,
                          kcal: kcal,
                          avgBpm: payload.avgHeartRateBpm,
                          maxBpm: maxBpm)
        phase = .saved
    }

    /// Dismiss the summary and go back to idle. Separate from `deliver` so the
    /// numbers survive until the user has actually looked at them.
    func clearSummary() {
        summary = nil
        phase = .idle
    }

    /// Mean of the once-a-second readings. Sampled at a fixed rate while unpaused,
    /// so this is already time-weighted and already excludes paused time — which is
    /// what the phone's after-the-fact HealthKit re-query has to work hard to
    /// approximate.
    private func averageBpm() -> Double {
        bpmSamples > 0 ? bpmSum / Double(bpmSamples) : 0
    }

    private static func hkActivity(_ type: ActivityType) -> HKWorkoutActivityType {
        switch type {
        case .walk: return .walking
        case .run:  return .running
        case .ride: return .cycling
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchWorkoutController: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        guard toState == .ended else { return }
        DispatchQueue.main.async { self.finish() }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.ticker?.invalidate()
            self.ticker = nil
            self.stopLocation()
            self.phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchWorkoutController: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let stats = workoutBuilder.statistics(for: quantityType) else { continue }
            apply(stats, for: quantityType)
        }
    }

    /// Matched with `==` on the identifier rather than `switch`-ing over the type
    /// objects: `HKQuantityType` is a class, and relying on pattern matching to
    /// compare instances is not something to bet a silent metric failure on.
    private func apply(_ stats: HKStatistics, for type: HKQuantityType) {
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let id = type.identifier

        if id == HKQuantityTypeIdentifier.heartRate.rawValue {
            let current = stats.mostRecentQuantity()?.doubleValue(for: bpmUnit) ?? 0
            let peak = stats.maximumQuantity()?.doubleValue(for: bpmUnit) ?? 0
            DispatchQueue.main.async {
                if current > 0 { self.bpm = current }
                if peak > self.maxBpm { self.maxBpm = peak }
            }
        } else if id == HKQuantityTypeIdentifier.activeEnergyBurned.rawValue {
            let value = stats.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            DispatchQueue.main.async { self.kcal = value }
        } else if id == HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue
                    || id == HKQuantityTypeIdentifier.distanceCycling.rawValue {
            let value = stats.sumQuantity()?.doubleValue(for: .meter()) ?? 0
            DispatchQueue.main.async { self.distanceMeters = value }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WatchWorkoutController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Same accuracy floor the phone uses — a 100-metre fix drawn on a map is
        // worse than no point at all.
        let usable = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 50 }
        guard !usable.isEmpty else { return }
        DispatchQueue.main.async {
            self.usedGPS = true
            self.latestSpeed = max(0, usable.last?.speed ?? 0)
            self.pendingLocations.append(contentsOf: usable)
            self.route.append(contentsOf: usable.map {
                WatchSessionPayload.Point(t: $0.timestamp,
                                          lat: $0.coordinate.latitude,
                                          lon: $0.coordinate.longitude,
                                          alt: $0.altitude,
                                          acc: $0.horizontalAccuracy,
                                          spd: max(0, $0.speed))
            })
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Losing GPS costs the map, not the run — HealthKit keeps measuring distance
        // from wrist motion regardless.
    }
}
