import Foundation
import SwiftData

/// One-time rescue of run history stranded in the shared App Group store.
///
/// Until v0.48 RunKit used `.modelContainer(for:)` with no configuration. That
/// resolves the group container *automatically*, so the App Group entitlement put
/// the store at
/// `<group.com.ferrixguild.suite>/Library/Application Support/default.store` — the
/// same generic filename LiftKit and FuelKit landed on, since all three are
/// entitled to the same group and none named a file. Every launch migrated that
/// one file to the launching app's schema and dropped the other apps' tables. The
/// container opened cleanly and saves succeeded; the rows were removed afterwards
/// by a sibling app.
///
/// v0.48 moves RunKit to its own explicitly named store. That leaves whatever
/// survived in the shared file unreachable, so this makes one attempt to bring it
/// across. Realistically little will be there — the shared file was last migrated
/// by LiftKit, so RunKit's tables were probably already dropped — but the attempt
/// is cheap and it costs a user nothing to try.
///
/// **The shared file is never opened directly.** It holds another app's data now,
/// and opening it with RunKit's schema would migrate it and destroy *that* data —
/// exactly the bug being fixed. Instead it is copied to a scratch directory and
/// the copy is opened, so the original is only ever read. The original is never
/// deleted either: no app can know which siblings are installed on this device or
/// whether they have migrated yet.
enum SharedStoreRecovery {
    private static let attemptedKey = "recoveredFromSharedStore.v1"

    /// Copy any RunKit records out of the old shared store, once.
    static func recoverIfNeeded(into container: ModelContainer,
                                defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: attemptedKey) else { return }

        let context = ModelContext(container)
        // Only recover into an empty history; never merge on top of real data.
        let existing = (try? context.fetchCount(FetchDescriptor<ActivitySession>())) ?? 0
        guard existing == 0 else {
            defaults.set(true, forKey: attemptedKey)
            return
        }

        defer { defaults.set(true, forKey: attemptedKey) }

        guard let shared = sharedStoreURL,
              FileManager.default.fileExists(atPath: shared.path),
              let scratch = copyAside(shared) else { return }
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        guard let recovered = try? ModelContainer(
            for: ActivitySession.self, RoutePoint.self,
            CustomWorkout.self, ScheduledRun.self,
            configurations: ModelConfiguration(url: scratch.store)
        ) else { return }

        let summary = copy(from: ModelContext(recovered), into: context)
        guard !summary.isEmpty else { return }

        if Persist.save(context, "recover shared store") {
            StoreHealth.shared.recordRecovery(summary.text)
        }
    }

    struct Summary {
        var sessions = 0
        var points = 0
        var templates = 0
        var scheduled = 0

        var isEmpty: Bool { sessions == 0 && templates == 0 && scheduled == 0 }

        var text: String {
            var parts: [String] = []
            if sessions > 0 { parts.append("\(sessions) session\(sessions == 1 ? "" : "s")") }
            if templates > 0 { parts.append("\(templates) saved workout\(templates == 1 ? "" : "s")") }
            if scheduled > 0 { parts.append("\(scheduled) scheduled run\(scheduled == 1 ? "" : "s")") }
            return "Recovered " + parts.joined(separator: ", ") + " from an earlier version."
        }
    }

    // MARK: - Copying records

    /// Rebuilds the object graph rather than moving objects, since they belong to a
    /// different container. Route points are re-attached to their session so maps
    /// and splits survive the move.
    private static func copy(from source: ModelContext, into destination: ModelContext) -> Summary {
        var summary = Summary()

        var sessionByID: [UUID: ActivitySession] = [:]
        for old in (try? source.fetch(FetchDescriptor<ActivitySession>())) ?? [] {
            let copy = ActivitySession(type: old.type, startedAt: old.startedAt)
            copy.id = old.id
            copy.endedAt = old.endedAt
            copy.activeSeconds = old.activeSeconds
            copy.pausedSeconds = old.pausedSeconds
            copy.distanceMeters = old.distanceMeters
            copy.steps = old.steps
            copy.flights = old.flights
            copy.activeEnergyKcal = old.activeEnergyKcal
            copy.usedGPS = old.usedGPS
            copy.manualDistance = old.manualDistance
            copy.distanceEstimated = old.distanceEstimated
            copy.goalKind = old.goalKind
            copy.goalTarget = old.goalTarget
            copy.workoutTypeRaw = old.workoutTypeRaw
            copy.intervalWork = old.intervalWork
            copy.intervalRest = old.intervalRest
            copy.intervalReps = old.intervalReps
            copy.paceTargetSecPerMeter = old.paceTargetSecPerMeter
            copy.customStepsJSON = old.customStepsJSON
            copy.customWorkoutName = old.customWorkoutName
            copy.avgHeartRateBpm = old.avgHeartRateBpm
            copy.maxHeartRateBpm = old.maxHeartRateBpm
            copy.hrZoneSecondsJSON = old.hrZoneSecondsJSON
            copy.hrCheckedAt = old.hrCheckedAt
            copy.decouplingPercent = old.decouplingPercent
            copy.hasDecoupling = old.hasDecoupling
            copy.decouplingNote = old.decouplingNote
            copy.notes = old.notes
            // Everything added since this copier was written. A field missed here is
            // silently dropped on recovery, which is the worst kind of data loss:
            // the sessions all survive, so nobody notices the pack weights and
            // treadmill flags went with them.
            copy.isIndoor = old.isIndoor
            copy.isPendingReview = old.isPendingReview
            copy.fromScheduleID = old.fromScheduleID
            copy.editedAt = old.editedAt
            copy.ruckWeightKg = old.ruckWeightKg
            copy.bodyweightKg = old.bodyweightKg
            copy.energyMeasured = old.energyMeasured
            destination.insert(copy)
            sessionByID[old.id] = copy
            summary.sessions += 1
        }

        for old in (try? source.fetch(FetchDescriptor<RoutePoint>())) ?? [] {
            guard let owner = old.session.flatMap({ sessionByID[$0.id] }) else { continue }
            let copy = RoutePoint(timestamp: old.timestamp,
                                  latitude: old.latitude,
                                  longitude: old.longitude,
                                  altitude: old.altitude,
                                  horizontalAccuracy: old.horizontalAccuracy,
                                  speed: old.speed,
                                  isEstimated: old.isEstimated)
            copy.session = owner
            destination.insert(copy)
            summary.points += 1
        }

        for old in (try? source.fetch(FetchDescriptor<CustomWorkout>())) ?? [] {
            let copy = CustomWorkout(name: old.name, segments: old.segments)
            copy.id = old.id
            copy.createdAt = old.createdAt
            copy.isFavorite = old.isFavorite
            destination.insert(copy)
            summary.templates += 1
        }

        for old in (try? source.fetch(FetchDescriptor<ScheduledRun>())) ?? [] {
            // Rebuilt field-by-field rather than through the `PendingWorkout`
            // initialiser, so a completed run stays completed and keeps its date.
            let copy = ScheduledRun(date: old.date, from: PendingWorkout(type: old.type))
            copy.id = old.id
            copy.title = old.title
            copy.typeRaw = old.typeRaw
            copy.workoutTypeRaw = old.workoutTypeRaw
            copy.meters = old.meters
            copy.minutes = old.minutes
            copy.work = old.work
            copy.rest = old.rest
            copy.reps = old.reps
            copy.stepsJSON = old.stepsJSON
            copy.isCompleted = old.isCompleted
            copy.completedAt = old.completedAt
            copy.seriesID = old.seriesID
            destination.insert(copy)
            summary.scheduled += 1
        }

        return summary
    }

    // MARK: - File handling

    private static var sharedStoreURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SuiteProfileStore.appGroupID)?
            .appending(path: "Library/Application Support/default.store")
    }

    /// Copies the store and its `-wal` / `-shm` companions to a scratch directory.
    /// The `-wal` matters: recent writes can still be sitting in it unmerged.
    private static func copyAside(_ store: URL) -> (directory: URL, store: URL)? {
        let directory = URL.temporaryDirectory.appending(path: "runkit-recovery-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory,
                                                       withIntermediateDirectories: true)) != nil
        else { return nil }
        let destination = directory.appending(path: store.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: store, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: store.path + suffix)
            if FileManager.default.fileExists(atPath: companion.path) {
                try? FileManager.default.copyItem(
                    at: companion,
                    to: URL(fileURLWithPath: destination.path + suffix)
                )
            }
        }
        return (directory, destination)
    }
}
