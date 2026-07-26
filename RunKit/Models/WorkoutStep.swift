import Foundation
import SwiftData

/// One segment of a custom structured workout — e.g. "10 min warm-up",
/// "5 mi @ 8:00", "1 mi @ 7:00", "1 mi cool-down walk".
///
/// A step ends on either a duration or a distance, and may carry a pace target.
/// Pace is stored **seconds per meter** so it survives a units switch; the UI
/// converts to /km or /mi for display and entry.
struct WorkoutStep: Codable, Hashable, Identifiable {

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case warmup, work, recovery, cooldown

        var id: String { rawValue }

        var label: String {
            switch self {
            case .warmup:   return "Warm-up"
            case .work:     return "Work"
            case .recovery: return "Recovery"
            case .cooldown: return "Cool-down"
            }
        }

        /// Spoken when the step begins.
        var spoken: String {
            switch self {
            case .warmup:   return "Warm up"
            case .work:     return "Work"
            case .recovery: return "Recover"
            case .cooldown: return "Cool down"
            }
        }

        var sfSymbol: String {
            switch self {
            case .warmup:   return "sunrise"
            case .work:     return "bolt.fill"
            case .recovery: return "wind"
            case .cooldown: return "sunset"
            }
        }
    }

    enum Basis: String, Codable, CaseIterable, Identifiable {
        case time, distance
        var id: String { rawValue }
        var label: String { self == .time ? "Time" : "Distance" }
    }

    var id: UUID = UUID()
    var kind: Kind = .work
    var basis: Basis = .time
    /// Used when `basis == .time`.
    var seconds: Double = 300
    /// Used when `basis == .distance`.
    var meters: Double = 1609.344
    /// 0 = no target (run it by feel).
    var paceTargetSecPerMeter: Double = 0

    var hasPaceTarget: Bool { paceTargetSecPerMeter > 0 }

    /// "10 min" / "5.0 km", in the user's units.
    func amountText(_ unit: UnitSystem) -> String {
        switch basis {
        case .time:
            let m = Int((seconds / 60).rounded())
            return m > 0 ? "\(m) min" : "\(Int(seconds)) sec"
        case .distance:
            let d = unit.distance(meters)
            let n = d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
            return "\(n) \(unit.distanceUnit)"
        }
    }

    /// "@ 8:00 /mi" or "" when the step has no target.
    func targetText(_ unit: UnitSystem) -> String {
        guard hasPaceTarget else { return "" }
        let perUnit = paceTargetSecPerMeter * (unit == .metric ? 1000 : 1609.344)
        return "@ " + unit.paceString(secondsPerUnit: perUnit)
    }

    func summary(_ unit: UnitSystem) -> String {
        let t = targetText(unit)
        return t.isEmpty ? amountText(unit) : "\(amountText(unit)) \(t)"
    }
}

// MARK: - Saved custom workouts

/// A reusable custom workout. Steps are stored as JSON rather than a SwiftData
/// relationship: to-many relationships have no guaranteed order, and for a
/// structured workout the **order is the workout**. A plain `String` attribute
/// also keeps the model trivially CloudKit-compatible.
@Model
final class CustomWorkout {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var stepsJSON: String = "[]"
    var isFavorite: Bool = false

    init(name: String, steps: [WorkoutStep]) {
        self.name = name
        self.steps = steps
    }

    var steps: [WorkoutStep] {
        get { WorkoutStep.decode(stepsJSON) }
        set { stepsJSON = WorkoutStep.encode(newValue) }
    }

    /// Total distance in meters, or nil when any step is time-based.
    var totalMeters: Double? {
        let s = steps
        guard s.allSatisfy({ $0.basis == .distance }) else { return nil }
        return s.reduce(0) { $0 + $1.meters }
    }
}

extension WorkoutStep {
    static func encode(_ steps: [WorkoutStep]) -> String {
        guard let data = try? JSONEncoder().encode(steps),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decode(_ json: String) -> [WorkoutStep] {
        guard let data = json.data(using: .utf8),
              let steps = try? JSONDecoder().decode([WorkoutStep].self, from: data)
        else { return [] }
        return steps
    }

    /// Sensible starting template: warm up, work, cool down.
    static var starter: [WorkoutStep] {
        [
            WorkoutStep(kind: .warmup, basis: .time, seconds: 600),
            WorkoutStep(kind: .work, basis: .distance, meters: 1609.344 * 3),
            WorkoutStep(kind: .cooldown, basis: .time, seconds: 300),
        ]
    }
}
