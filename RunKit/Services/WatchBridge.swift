import Foundation
import SwiftData
import WatchConnectivity

/// The iPhone half of the watch link.
///
/// One job for now: push the current menu — today's scheduled runs, the prebuilt
/// library, saved workouts — to the watch as **application context**. Last-state
/// wins, the system coalesces repeats, and delivery happens whenever the watch next
/// wakes. A menu is state rather than an event, so nothing needs queueing or
/// replaying, and `WCSession.receivedApplicationContext` persists it on the watch
/// for free.
///
/// The watch records its own runs, so there is no "start" message coming back the
/// other way. Finished sessions will arrive by file transfer — added with the
/// session engine, not before.
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    /// Set at launch by `RunKitApp`. Runs arrive by file transfer while no view is
    /// on screen — often with the app woken in the background — so importing them
    /// can't depend on a `@Environment` context from a view that may not exist.
    var container: ModelContainer?

    /// Last menu handed to the system, so an unchanged one isn't re-sent on every
    /// foreground. `WatchMenu` is `Hashable` precisely for this comparison.
    private var lastSent: WatchMenu?

    /// Resting HR, read from Health once and cached. Refreshed by `refreshHRInputs`.
    private var restingHR: Double = 0

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// Tell the watch this phone has started or stopped recording, so it warns
    /// rather than starting a second recording of the same run. Best-effort — out
    /// of range there's no message and nothing worth reporting.
    func announceRecording(_ recording: Bool, label: String) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isReachable else { return }
        session.sendMessage(RecordingOwner.message(recording: recording, label: label),
                            replyHandler: nil) { _ in }
    }

    /// Called once at launch. Safe to call again; activation is idempotent.
    func activate() {
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated { session.activate() }
    }

    /// Rebuilds the menu and pushes it if anything changed. Cheap enough to call on
    /// every foreground and after any edit to a workout or a schedule.
    @MainActor
    func publish(from context: ModelContext, unit: UnitSystem) {
        guard let session, session.activationState == .activated, session.isPaired else { return }

        let menu = buildMenu(from: context, unit: unit)
        guard menu != lastSent else { return }
        guard let data = WatchLink.encode(menu) else { return }
        do {
            try session.updateApplicationContext([WatchLink.menuKey: data])
            lastSent = menu
        } catch {
            // Not worth surfacing: the next foreground republishes, and a watch
            // holding a slightly stale menu still works.
        }
    }

    // MARK: - Building the menu

    /// Pulls the resting heart rate the zone maths needs. Async and cached, because
    /// `publish` runs synchronously on every foreground and must not await Health.
    func refreshHRInputs() async {
        if let resting = await HealthService.shared.latestRestingHeartRate(), resting > 0 {
            await MainActor.run {
                self.restingHR = resting
                self.lastSent = nil     // zone bounds changed — force a republish
            }
        }
    }

    @MainActor
    private func buildMenu(from context: ModelContext, unit: UnitSystem) -> WatchMenu {
        // Resolved here rather than on the watch: this is the side that has the
        // user's max-HR override and their age from the suite profile.
        let override = UserDefaults.standard.double(forKey: "maxHeartRate")
        let maxHR = HeartRateZones.maxHeartRate(override: override,
                                                observed: nil,
                                                age: SuiteProfileStore.load()?.age ?? 0)
        return WatchMenu(unitRaw: unit.rawValue,
                         scheduledToday: Self.scheduledItems(context),
                         recipes: Self.recipeItems(),
                         custom: Self.customItems(context),
                         maxHR: maxHR,
                         restingHR: restingHR)
    }

    /// Due today, plus anything carried forward from a missed day — the same rule
    /// `TodayView` uses, so the watch suggests exactly what the phone does.
    @MainActor
    private static func scheduledItems(_ context: ModelContext) -> [WatchMenu.Item] {
        let today = Calendar.current.startOfDay(for: Date())
        var descriptor = FetchDescriptor<ScheduledRun>(
            predicate: #Predicate { !$0.isCompleted && $0.date <= today },
            sortBy: [SortDescriptor(\.date)])
        descriptor.fetchLimit = 5
        let runs = (try? context.fetch(descriptor)) ?? []
        return runs.map { run in
            WatchMenu.Item(name: run.title.isEmpty ? run.workoutType.label : run.title,
                           // Via `PendingWorkout` so runs scheduled before v0.45,
                           // which stored flat parameters and no cards, still
                           // resolve to something runnable.
                           segments: PendingWorkout(scheduled: run).resolvedSegments,
                           source: .scheduled,
                           referenceID: run.id)
        }
    }

    private static func recipeItems() -> [WatchMenu.Item] {
        WorkoutRecipe.all.map { recipe in
            WatchMenu.Item(name: recipe.name,
                           segments: ActivitySegment.from(recipe: recipe),
                           source: .recipe,
                           category: recipe.category.rawValue,
                           recipeName: recipe.name)
        }
    }

    /// Favourites first, then newest — matching `TodayView.orderedTemplates`. Capped
    /// because a watch list past ~30 rows is unusable with a crown anyway, and the
    /// application context is not the place for an unbounded payload.
    @MainActor
    private static func customItems(_ context: ModelContext) -> [WatchMenu.Item] {
        let descriptor = FetchDescriptor<CustomWorkout>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        let ordered = all.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.createdAt > b.createdAt
        }
        return ordered.prefix(30).map { workout in
            WatchMenu.Item(name: workout.name.isEmpty ? "Untitled" : workout.name,
                           segments: workout.segments,
                           source: .custom,
                           referenceID: workout.id)
        }
    }
}

// MARK: - WCSessionDelegate

/// Delegate callbacks arrive on a background queue, so anything touching `lastSent`
/// hops to the main queue first.
extension WatchBridge: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        // Nothing to do — publishing is driven by the app, not by activation.
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Fired when the user switches to a different paired watch. Reactivating binds
    /// the session to the new one; without this the link silently dies.
    func sessionDidDeactivate(_ session: WCSession) {
        DispatchQueue.main.async { self.lastSent = nil }
        session.activate()
    }

    /// A watch that has just been paired, or has just installed the app, needs the
    /// menu it missed. Clearing `lastSent` makes the next publish go out even if
    /// the content is unchanged.
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.lastSent = nil }
    }

    /// The watch telling us it started or stopped a run.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { RecordingOwner.shared.handle(message: message) }
    }

    /// A run recorded on the wrist.
    ///
    /// The file is deleted the moment this method returns, so the bytes are read
    /// **synchronously** here and the import is dispatched with the data in hand.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL),
              let payload = WatchLink.decode(WatchSessionPayload.self, from: data) else { return }
        DispatchQueue.main.async { self.importSession(payload) }
    }
}

// MARK: - Importing a wrist-recorded run

extension WatchBridge {

    @MainActor
    func importSession(_ payload: WatchSessionPayload) {
        guard let container else { return }
        let context = ModelContext(container)

        // WatchConnectivity can deliver a queued file more than once, and the watch
        // resends on failure. The payload id is stable across those retries, so this
        // fetch is what stops a run being logged twice.
        let id = payload.id
        var existing = FetchDescriptor<ActivitySession>(predicate: #Predicate { $0.id == id })
        existing.fetchLimit = 1
        guard (try? context.fetch(existing))?.isEmpty ?? true else { return }

        let s = ActivitySession(type: payload.activity, startedAt: payload.startedAt)
        s.id = payload.id
        s.endedAt = payload.endedAt
        s.activeSeconds = payload.activeSeconds
        s.pausedSeconds = payload.pausedSeconds
        s.distanceMeters = payload.distanceMeters
        s.activeEnergyKcal = payload.activeEnergyKcal
        s.usedGPS = payload.usedGPS
        s.avgHeartRateBpm = payload.avgHeartRateBpm
        s.maxHeartRateBpm = payload.maxHeartRateBpm
        s.hrZoneSecondsJSON = HeartRateZones.encode(payload.hrZoneSeconds)
        // Already summarised on the wrist from live samples, so backfill must not
        // re-examine it — and a non-nil `hrCheckedAt` is how backfill knows to skip.
        s.hrCheckedAt = Date()
        s.customStepsJSON = ActivitySegment.encode(payload.segments)
        s.customWorkoutName = payload.workoutName
        s.workoutTypeRaw = ActivitySegment.workoutType(for: payload.segments).rawValue

        // Session first: the route points set a relationship to it, and attaching to
        // an object the context doesn't know about yet is asking for trouble.
        context.insert(s)
        for p in payload.route {
            let point = RoutePoint(timestamp: p.t, latitude: p.lat, longitude: p.lon,
                                   altitude: p.alt, horizontalAccuracy: p.acc, speed: p.spd)
            point.session = s
            context.insert(point)
        }

        if let scheduleID = payload.scheduleID {
            var descriptor = FetchDescriptor<ScheduledRun>(predicate: #Predicate { $0.id == scheduleID })
            descriptor.fetchLimit = 1
            if let run = try? context.fetch(descriptor).first, !run.isCompleted {
                run.isCompleted = true
                run.completedAt = payload.endedAt
            }
        }

        Persist.save(context, "watch session import")

        // Deliberately NOT written to HealthKit. The watch already saved this run,
        // with its own route — saving again would put a duplicate workout in Health
        // and double the active energy, which then flows into FuelKit as real intake
        // headroom.

        SuiteActivityPublisher.publish(from: context)
        let unit = UnitSystem(rawValue: UserDefaults.standard.string(forKey: "unitSystem") ?? "") ?? .metric
        publish(from: context, unit: unit)
    }
}
