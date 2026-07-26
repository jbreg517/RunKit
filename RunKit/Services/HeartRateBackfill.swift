import Foundation
import SwiftData

/// Fills in each session's heart-rate summary from HealthKit.
///
/// Runs at save time for new sessions and as a bounded catch-up pass for older
/// ones — sessions recorded before v0.41, or recorded before the user granted
/// Health access. Everything is best-effort: no HR simply leaves the summary at
/// zero, which the UI reads as "no data".
@MainActor
enum HeartRateBackfill {

    /// Populates one session's HR summary. Safe to call repeatedly; stamps
    /// `hrCheckedAt` so a session without a Watch isn't re-queried forever.
    static func fill(_ session: ActivitySession, zones: [HeartRateZones.Zone]) async {
        guard let end = session.endedAt else { return }
        let samples = await HealthService.shared.heartRateSamples(from: session.startedAt, to: end)
        let summary = HeartRateZones.summarize(samples, zones: zones, sessionEnd: end)
        session.avgHeartRateBpm = summary.average
        session.maxHeartRateBpm = summary.maximum
        session.hrZoneSecondsJSON = HeartRateZones.encode(summary.zoneSeconds)
        session.hrCheckedAt = Date()

        // Decoupling reuses the samples already fetched — no second query.
        if let reason = AerobicAnalysis.eligibility(session) {
            session.hasDecoupling = false
            session.decouplingNote = reason.rawValue
        } else if let result = AerobicAnalysis.decoupling(session, samples: samples) {
            session.decouplingPercent = result.percent
            session.hasDecoupling = true
            session.decouplingNote = result.summary
        } else {
            session.hasDecoupling = false
            session.decouplingNote = samples.isEmpty
                ? AerobicAnalysis.Ineligible.noHeart.rawValue
                : AerobicAnalysis.Ineligible.notEnough.rawValue
        }
    }

    /// Catch-up pass over sessions never examined. Capped per run so opening
    /// Stats never blocks on a long history; the next visit picks up the rest.
    /// Returns true if anything changed.
    @discardableResult
    static func catchUp(_ sessions: [ActivitySession], zones: [HeartRateZones.Zone],
                        limit: Int = 25, context: ModelContext) async -> Bool {
        let pending = sessions
            .filter { $0.endedAt != nil && $0.hrCheckedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }   // newest first — most useful
            .prefix(limit)
        guard !pending.isEmpty else { return false }
        for s in pending {
            await fill(s, zones: zones)
        }
        try? context.save()
        return true
    }
}
