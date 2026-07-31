import Foundation
import SwiftData
import WatchConnectivity

/// The iPhone half of the watch link.
///
/// Two jobs, and only two:
///  1. Push the current menu (today's scheduled runs, the prebuilt library, saved
///     workouts) to the watch as **application context** — last-state-wins, coalesced
///     by the system, delivered whenever the watch next wakes. A menu is state, not
///     an event, so nothing needs queueing or replaying.
///  2. Answer a start request from the watch by handing the workout to `AppRouter`.
///
/// Start requests use `sendMessage`, which only works while the watch and phone are
/// actually in contact, and that is the right behaviour: a queued "start my run"
/// arriving twenty minutes later would be worse than a failure the user can see.
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    /// Set by `RootTabView` once the router and model context exist. Called on the
    /// main queue.
    var onStart: ((WatchMenu.Item) -> Void)?

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
        guard let session, session.activationState == .activated else { return }
        // A paired watch that has never installed the app still gets the context
        // stored, which is what we want — it's there the moment the app is opened.
        guard session.isPaired else { return }

        let menu = Self.buildMenu(from: context, unit: unit)
        guard menu != lastSent else { return }
        guard let data = WatchLink.encode(menu) else { return }
        do {
            try session.updateApplicationContext([WatchLink.menuKey: data])
            lastSent = menu
        } catch {
            // Not worth surfacing: the next foreground republishes, and a watch
            // with a stale menu still works.
        }
    }

    // MARK: - Building the menu

    @MainActor
    private static func buildMenu(from context: ModelContext, unit: UnitSystem) -> WatchMenu {
        WatchMenu(scheduledToday: scheduledItems(context, unit),
                  recipes: recipeItems(),
                  custom: customItems(context, unit))
    }

    /// Due today, plus anything carried forward from a missed day — the same rule
    /// `TodayView` uses, so the watch suggests exactly what the phone does.
    @MainActor
    private static func scheduledItems(_ context: ModelContext, _ unit: UnitSystem) -> [WatchMenu.Item] {
        let today = Calendar.current.startOfDay(for: Date())
        var descriptor = FetchDescriptor<ScheduledRun>(
            predicate: #Predicate { !$0.isCompleted && $0.date <= today },
            sortBy: [SortDescriptor(\.date)])
        descriptor.fetchLimit = 5
        let runs = (try? context.fetch(descriptor)) ?? []
        return runs.map { run in
            WatchMenu.Item(name: run.title.isEmpty ? run.workoutType.label : run.title,
                           summary: run.summary(unit),
                           activityRaw: run.type.rawValue,
                           source: .scheduled,
                           referenceID: run.id)
        }
    }

    private static func recipeItems() -> [WatchMenu.Item] {
        WorkoutRecipe.all.map { recipe in
            WatchMenu.Item(name: recipe.name,
                           summary: recipe.summary,
                           activityRaw: ActivityType.run.rawValue,
                           source: .recipe,
                           category: recipe.category.rawValue,
                           recipeName: recipe.name)
        }
    }

    /// Favourites first, then newest — matching `TodayView.orderedTemplates`. Capped
    /// because a watch list past ~30 rows is unusable with a crown anyway, and the
    /// application context is not the place for an unbounded payload.
    @MainActor
    private static func customItems(_ context: ModelContext, _ unit: UnitSystem) -> [WatchMenu.Item] {
        let descriptor = FetchDescriptor<CustomWorkout>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        let ordered = all.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.createdAt > b.createdAt
        }
        return ordered.prefix(30).map { workout in
            let cards = workout.segments
            let summary: String
            if cards.count > 1 {
                summary = "\(cards.count) cards · \(cards[0].summary(unit))"
            } else {
                summary = cards.first?.summary(unit) ?? "Open run"
            }
            return WatchMenu.Item(name: workout.name.isEmpty ? "Untitled" : workout.name,
                                  summary: summary,
                                  activityRaw: (cards.first?.activity ?? .run).rawValue,
                                  source: .custom,
                                  referenceID: workout.id)
        }
    }

    // MARK: - Resolving a start request

    /// Turns what the watch sent back into the real workout. Looked up fresh rather
    /// than reconstructed from the payload: the watch's copy of the menu can be
    /// hours old, and the workout it names may have been edited since.
    @MainActor
    static func pendingWorkout(for item: WatchMenu.Item, in context: ModelContext) -> PendingWorkout? {
        let activity = ActivityType(rawValue: item.activityRaw) ?? .run
        switch item.source {
        case .quick:
            return PendingWorkout(type: activity)

        case .recipe:
            guard let recipe = WorkoutRecipe.all.first(where: { $0.name == item.recipeName })
            else { return nil }
            return PendingWorkout(recipe: recipe, type: activity)

        case .custom:
            guard let id = item.referenceID else { return nil }
            var descriptor = FetchDescriptor<CustomWorkout>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let workout = try? context.fetch(descriptor).first else { return nil }
            return PendingWorkout(custom: workout, type: activity)

        case .scheduled:
            guard let id = item.referenceID else { return nil }
            var descriptor = FetchDescriptor<ScheduledRun>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let run = try? context.fetch(descriptor).first else { return nil }
            return PendingWorkout(scheduled: run)
        }
    }
}

// MARK: - WCSessionDelegate

/// Delegate callbacks arrive on a background queue, so everything that touches the
/// router or the model context hops to the main queue first.
extension WatchBridge: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        // Nothing to do — `publish` is driven by the app, not by activation.
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Fired when the user switches to a different paired watch. Reactivating binds
    /// the session to the new one; without this the link silently dies.
    func sessionDidDeactivate(_ session: WCSession) {
        DispatchQueue.main.async { self.lastSent = nil }
        session.activate()
    }

    /// A watch that has just been paired, or has just installed the app, needs the
    /// menu it missed. Clearing `lastSent` forces the next publish to go out.
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.lastSent = nil }
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let item = WatchLink.decode(WatchMenu.Item.self, from: message[WatchLink.startKey]) else {
            replyHandler([WatchLink.acceptedKey: false])
            return
        }
        DispatchQueue.main.async {
            guard let onStart = self.onStart else {
                replyHandler([WatchLink.acceptedKey: false])
                return
            }
            onStart(item)
            replyHandler([WatchLink.acceptedKey: true])
        }
    }
}
