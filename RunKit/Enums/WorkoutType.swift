import Foundation

/// The single "run type" picker. Free is open; Distance/Time set a target;
/// Intervals repeats work/rest; Pace holds a target pace with over/under cues.
enum WorkoutType: String, CaseIterable, Identifiable {
    case free, distance, time, intervals, pace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free:      return "Free"
        case .distance:  return "Distance"
        case .time:      return "Time"
        case .intervals: return "Intervals"
        case .pace:      return "Pace"
        }
    }

    var sfSymbol: String {
        switch self {
        case .free:      return "infinity"
        case .distance:  return "ruler"
        case .time:      return "timer"
        case .intervals: return "repeat"
        case .pace:      return "speedometer"
        }
    }
}

/// Preset chips for the Intervals setup — "Sprints" is just an interval preset,
/// keeping the type menu to five.
struct IntervalPreset: Identifiable {
    let name: String
    let work: Int   // seconds
    let rest: Int   // seconds
    let reps: Int
    var id: String { name }

    static let all: [IntervalPreset] = [
        IntervalPreset(name: "Sprints", work: 30, rest: 90, reps: 8),
        IntervalPreset(name: "400s",    work: 90, rest: 120, reps: 6),
        IntervalPreset(name: "1 / 1",   work: 60, rest: 60, reps: 10),
    ]
}
