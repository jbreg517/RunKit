import Foundation

/// How a finished (or scheduled) session is *classified* — the one label Stats,
/// History and `AerobicAnalysis` sort by.
///
/// Since v0.45 this is no longer something the user picks. Sessions are built from
/// `ActivitySegment` cards, and `ActivitySegment.workoutType(for:)` collapses the
/// card list down to one of these: a single card takes its goal's name, and
/// anything with more than one card is `.custom` — "Structured".
enum WorkoutType: String, CaseIterable, Identifiable {
    case free, distance, time, intervals, pace, heartRate, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free:      return "Free"
        case .distance:  return "Distance"
        case .time:      return "Time"
        case .intervals: return "Intervals"
        case .pace:      return "Pace"
        case .heartRate: return "Heart Rate"
        case .custom:    return "Structured"
        }
    }

    var sfSymbol: String {
        switch self {
        case .free:      return "infinity"
        case .distance:  return "ruler"
        case .time:      return "timer"
        case .intervals: return "repeat"
        case .pace:      return "speedometer"
        case .heartRate: return "heart.fill"
        case .custom:    return "list.bullet.indent"
        }
    }
}

/// Preset chips for an intervals card, so the common shapes are one tap.
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
