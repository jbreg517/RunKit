import Foundation
import SwiftData

/// Everything that happens to a run once the user accepts it.
///
/// A finished run is written to RunKit's own store immediately — losing it would be
/// unforgivable — but held back from **everywhere it can't easily be taken out of
/// again**: Apple Health, the suite feed FuelKit reads, and the scheduled run it
/// would tick off. Those wait for Save.
///
/// One implementation, two callers: the review screen when the user taps Save, and
/// the launch sweep for a run whose review screen was killed. Splitting them would
/// mean a force-quit produced a subtly different record than a tap.
@MainActor
enum PendingRunCommit {

    /// Accept a run: publish it, save it to Health, and tick off its plan entry.
    /// Idempotent — a session that isn't pending is left alone, so a duplicate call
    /// can't write the workout to Health twice.
    static func commit(_ session: ActivitySession, in context: ModelContext) async {
        guard session.isPendingReview else { return }
        session.isPendingReview = false

        if let id = session.fromScheduleID {
            var descriptor = FetchDescriptor<ScheduledRun>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let scheduled = try? context.fetch(descriptor).first, !scheduled.isCompleted {
                scheduled.isCompleted = true
                scheduled.completedAt = session.endedAt ?? Date()
            }
        }

        // Cleared first so a crash between here and the Health write leaves the run
        // settled rather than pending — at worst it's missing from Health, which the
        // user can see and act on. A run stuck pending forever would keep being
        // re-committed on every launch.
        Persist.save(context, "commit run")

        SuiteActivityPublisher.publish(from: context)
        WatchBridge.shared.publish(from: context, unit: currentUnit)
        WatchBridge.shared.announceRecording(false, label: "")

        await HealthService.shared.save(session)

        // After the workout save, so Health has something to attribute samples to.
        let resting = await HealthService.shared.latestRestingHeartRate()
        let maxHR = HeartRateZones.maxHeartRate(
            override: UserDefaults.standard.double(forKey: "maxHeartRate"),
            observed: nil,
            age: SuiteProfileStore.load()?.age ?? 0)
        await HeartRateBackfill.fill(session, zones: HeartRateZones.zones(maxHR: maxHR,
                                                                         restingHR: resting))
    }

    /// Throw a run away. Nothing has reached Health or the suite yet, so this is a
    /// plain delete — which is exactly why the write is deferred in the first place.
    static func discard(_ session: ActivitySession, in context: ModelContext) {
        context.delete(session)   // route points cascade
        Persist.save(context, "discard run")
    }

    /// Commit anything left pending by a previous launch.
    ///
    /// This is what makes a force-quit at the review screen safe: the run was
    /// already in RunKit's store, and now it reaches Health too. Committed **as
    /// recorded**, since there is no way to know what the user would have edited —
    /// and an unedited run in Health beats no run at all.
    static func sweep(_ context: ModelContext) async {
        let descriptor = FetchDescriptor<ActivitySession>(
            predicate: #Predicate { $0.isPendingReview && $0.endedAt != nil })
        guard let orphans = try? context.fetch(descriptor), !orphans.isEmpty else { return }
        for session in orphans {
            await commit(session, in: context)
        }
    }

    private static var currentUnit: UnitSystem {
        UnitSystem(rawValue: UserDefaults.standard.string(forKey: "unitSystem") ?? "") ?? .metric
    }
}
