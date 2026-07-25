import Foundation

/// Heart-rate zones and per-session HR summaries.
///
/// Zones use **heart-rate reserve (Karvonen)** whenever a resting HR is known,
/// because plain %max misstates the low zones badly. Falls back to %max only
/// when resting HR is unavailable.
///
/// `220 − age` is used only as a last resort for max HR: it's off by ±10–12 bpm
/// for many people, so an observed max from the user's own history — or an
/// explicit override — is always preferred.
enum HeartRateZones {

    struct Zone: Identifiable {
        let index: Int          // 1...5
        let name: String
        let lower: Double       // bpm
        let upper: Double
        var id: Int { index }
    }

    /// Fraction-of-reserve boundaries; index 0 is the floor of zone 1.
    private static let bounds: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]
    private static let names = ["Recovery", "Easy", "Steady", "Threshold", "VO₂ max"]

    /// - Parameters:
    ///   - maxHR: observed or user-set maximum.
    ///   - restingHR: enables the Karvonen model; nil falls back to %max.
    static func zones(maxHR: Double, restingHR: Double?) -> [Zone] {
        guard maxHR > 0 else { return [] }
        let resting = (restingHR ?? 0) > 0 ? restingHR! : 0
        let reserve = maxHR - resting
        return (0..<5).map { i in
            Zone(index: i + 1,
                 name: names[i],
                 lower: resting + reserve * bounds[i],
                 upper: resting + reserve * bounds[i + 1])
        }
    }

    /// Best available max HR: an explicit override, else the highest sample the
    /// user has actually recorded, else the age formula.
    static func maxHeartRate(override: Double, observed: Double?, age: Int) -> Double {
        if override > 0 { return override }
        if let observed, observed > 0 { return observed }
        return age > 0 ? Double(220 - age) : 190
    }

    // MARK: Session summary

    struct Summary: Equatable {
        var average = 0.0
        var maximum = 0.0
        /// Seconds spent in each of the five zones, index 0 = zone 1.
        var zoneSeconds: [Double] = Array(repeating: 0, count: 5)

        var hasData: Bool { average > 0 }
        var totalZoneSeconds: Double { zoneSeconds.reduce(0, +) }
    }

    /// Summarises samples, attributing the gap between consecutive readings to the
    /// earlier one's zone. Apple Watch samples irregularly (every few seconds when
    /// active, sparser otherwise), so counting samples rather than elapsed time
    /// would badly skew the distribution.
    static func summarize(_ samples: [(date: Date, bpm: Double)],
                          zones: [Zone], sessionEnd: Date?) -> Summary {
        guard !samples.isEmpty else { return Summary() }
        var s = Summary()
        s.average = samples.map(\.bpm).reduce(0, +) / Double(samples.count)
        s.maximum = samples.map(\.bpm).max() ?? 0

        guard !zones.isEmpty else { return s }
        for (i, sample) in samples.enumerated() {
            let next = i + 1 < samples.count ? samples[i + 1].date : (sessionEnd ?? sample.date)
            // Clamp: a long gap means the watch stopped sampling, not that the
            // runner held that HR for minutes.
            let seconds = min(max(0, next.timeIntervalSince(sample.date)), 60)
            let zi = zoneIndex(for: sample.bpm, zones: zones)
            s.zoneSeconds[zi] += seconds
        }
        return s
    }

    /// 0-based index, clamped into range so anything below zone 1 counts as
    /// recovery and anything above zone 5 counts as VO₂ max.
    static func zoneIndex(for bpm: Double, zones: [Zone]) -> Int {
        guard let first = zones.first else { return 0 }
        if bpm < first.upper { return 0 }
        for z in zones where bpm < z.upper { return z.index - 1 }
        return zones.count - 1
    }

    // MARK: Encoding (stored on the session)

    static func encode(_ zoneSeconds: [Double]) -> String {
        guard let d = try? JSONEncoder().encode(zoneSeconds),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    static func decode(_ json: String) -> [Double] {
        guard let d = json.data(using: .utf8),
              let v = try? JSONDecoder().decode([Double].self, from: d),
              v.count == 5 else { return Array(repeating: 0, count: 5) }
        return v
    }
}
