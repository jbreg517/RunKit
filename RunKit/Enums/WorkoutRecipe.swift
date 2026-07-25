import Foundation

/// A named, ready-to-run workout that configures a session's `WorkoutType` and
/// its parameters.
///
/// Data only — the engine that runs these already shipped in v0.15. Shipping a
/// real workout library **free and offline, with no account**, is a deliberate
/// contrast to NRC (login-gated) and Strava (paywalled). It also de-risks the v2
/// training-plan generator, which is essentially "this library, sequenced".
///
/// Deliberately no `.pace` recipes: a pace target only means something relative
/// to the runner's own fitness, and inventing a number for everyone would break
/// the "honest estimates" principle. Tempo-style efforts are prescribed by
/// duration with effort described in `coaching` instead. The v2 plan generator
/// will derive real paces from the user's own history.
struct WorkoutRecipe: Identifiable, Hashable {

    enum Category: String, CaseIterable, Identifiable {
        case beginner, speed, endurance, hills, recovery

        var id: String { rawValue }

        var label: String {
            switch self {
            case .beginner:  return "Start out"
            case .speed:     return "Speed"
            case .endurance: return "Endurance"
            case .hills:     return "Hills"
            case .recovery:  return "Recovery"
            }
        }

        var sfSymbol: String {
            switch self {
            case .beginner:  return "figure.walk"
            case .speed:     return "bolt.fill"
            case .endurance: return "point.topleft.down.curvedto.point.bottomright.up"
            case .hills:     return "mountain.2.fill"
            case .recovery:  return "leaf.fill"
            }
        }
    }

    let name: String
    /// One-line shape of the workout, e.g. "8 × 60s run / 90s walk".
    let summary: String
    /// How to actually run it — effort, not numbers.
    let coaching: String
    let category: Category
    let workoutType: WorkoutType

    var meters: Double = 0   // used when workoutType == .distance
    var minutes: Int = 0     // used when workoutType == .time
    var work: Int = 0        // seconds, .intervals
    var rest: Int = 0        // seconds, .intervals
    var reps: Int = 0        // .intervals

    var id: String { name }

    static func inCategory(_ c: Category) -> [WorkoutRecipe] {
        all.filter { $0.category == c }
    }

    static let all: [WorkoutRecipe] = [

        // MARK: Start out — a couch-to-5K style ramp
        WorkoutRecipe(
            name: "First Steps", summary: "8 × 60s run / 90s walk",
            coaching: "Run easy enough to hold a conversation. Walk the rests properly.",
            category: .beginner, workoutType: .intervals, work: 60, rest: 90, reps: 8),
        WorkoutRecipe(
            name: "Building Up", summary: "6 × 90s run / 2min walk",
            coaching: "Same easy effort, longer efforts. Stop if your form falls apart.",
            category: .beginner, workoutType: .intervals, work: 90, rest: 120, reps: 6),
        WorkoutRecipe(
            name: "Five by Five", summary: "3 × 5min run / 90s walk",
            coaching: "The first sustained blocks. Start slower than feels right.",
            category: .beginner, workoutType: .intervals, work: 300, rest: 90, reps: 3),
        WorkoutRecipe(
            name: "First 20 Minutes", summary: "20 min continuous",
            coaching: "No walk breaks. Pace doesn't matter — finishing does.",
            category: .beginner, workoutType: .time, minutes: 20),

        // MARK: Speed
        WorkoutRecipe(
            name: "Sprints", summary: "8 × 30s hard / 90s easy",
            coaching: "Near-max on the efforts. Fully recover between them.",
            category: .speed, workoutType: .intervals, work: 30, rest: 90, reps: 8),
        WorkoutRecipe(
            name: "400s", summary: "6 × 90s fast / 2min easy",
            coaching: "Around 5K race effort — hard, but repeatable to the last rep.",
            category: .speed, workoutType: .intervals, work: 90, rest: 120, reps: 6),
        WorkoutRecipe(
            name: "Yasso 800s", summary: "6 × 3min / 3min jog",
            coaching: "A marathon-prediction classic. Even effort across all six.",
            category: .speed, workoutType: .intervals, work: 180, rest: 180, reps: 6),
        WorkoutRecipe(
            name: "Fartlek", summary: "10 × 60s on / 60s off",
            coaching: "Swedish for 'speed play'. Vary the efforts, keep moving throughout.",
            category: .speed, workoutType: .intervals, work: 60, rest: 60, reps: 10),

        // MARK: Endurance
        WorkoutRecipe(
            name: "Easy 5K", summary: "5 km steady",
            coaching: "Conversational the whole way. This is the bread-and-butter run.",
            category: .endurance, workoutType: .distance, meters: 5000),
        WorkoutRecipe(
            name: "Easy 10K", summary: "10 km steady",
            coaching: "Same easy effort, twice the distance. Negative-split it if you can.",
            category: .endurance, workoutType: .distance, meters: 10000),
        WorkoutRecipe(
            name: "Long Run", summary: "60 min continuous",
            coaching: "Time on feet is the point. Slower than you think, longer than you'd like.",
            category: .endurance, workoutType: .time, minutes: 60),
        WorkoutRecipe(
            name: "Tempo 20", summary: "20 min comfortably hard",
            coaching: "Threshold effort — you could speak a sentence, not a paragraph.",
            category: .endurance, workoutType: .time, minutes: 20),

        // MARK: Hills
        WorkoutRecipe(
            name: "Hill Repeats", summary: "8 × 60s up / 2min down",
            coaching: "Find a moderate grade. Drive the knees; jog the descents to recover.",
            category: .hills, workoutType: .intervals, work: 60, rest: 120, reps: 8),
        WorkoutRecipe(
            name: "Short Hills", summary: "10 × 30s up / 90s down",
            coaching: "Steeper and sharper. Pure power — walk down if you need to.",
            category: .hills, workoutType: .intervals, work: 30, rest: 90, reps: 10),

        // MARK: Recovery
        WorkoutRecipe(
            name: "Shakeout", summary: "15 min very easy",
            coaching: "The day after something hard. Deliberately, almost insultingly slow.",
            category: .recovery, workoutType: .time, minutes: 15),
        WorkoutRecipe(
            name: "Recovery Jog", summary: "25 min very easy",
            coaching: "Flush the legs out. If it feels like training, slow down.",
            category: .recovery, workoutType: .time, minutes: 25),
    ]
}
