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

    /// Last menu handed to the system, so an unchanged one isn't re-sent on every
    /// foreground. `WatchMenu` is `Hashable` precisely for this comparison.
    private var lastSent: WatchMenu?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
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

        let menu = Self.buildMenu(from: context, unit: unit)
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

    @MainActor
    private static func buildMenu(from context: ModelContext, unit: UnitSystem) -> WatchMenu {
        WatchMenu(unitRaw: unit.rawValue,
                  scheduledToday: scheduledItems(context),
                  recipes: recipeItems(),
                  custom: customItems(context))
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
}
