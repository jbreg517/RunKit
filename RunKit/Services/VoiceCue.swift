import Foundation

/// A spoken announcement described structurally (not as a finished string), so a
/// clip-based coach can map it to audio clips while the system coach renders it to
/// a sentence. `motivationIndex` is chosen by the caller so both coaches use the
/// same line.
enum VoiceCue {
    case go
    case mark(unit: UnitSystem, type: ActivityType, index: Int, elapsed: TimeInterval, meters: Double)
    case goalReached(GoalKind, target: Double, unit: UnitSystem, motivationIndex: Int)
    case finish(type: ActivityType, unit: UnitSystem, meters: Double, seconds: TimeInterval, motivationIndex: Int)
    case sample
}

/// Strategy for speaking a cue. `SystemVoiceCoach` (AVSpeechSynthesizer) is the
/// always-available fallback; `ClipVoiceCoach` plays bundled audio when present.
protocol VoiceCoach: AnyObject {
    func speak(_ cue: VoiceCue)        // mid-session; keeps the audio session active
    func speakFinal(_ cue: VoiceCue)   // releases the audio session once finished
    func stop()
}

/// One unit of an announcement: an optional audio clip plus the text it
/// contributes to the system-TTS sentence. `clipID == nil` is a pause/punctuation.
struct VoiceToken {
    var clipID: String?
    var text: String
}

/// Turns a `VoiceCue` into an ordered token list. Both coaches consume this — the
/// single source of truth for sequencing (singular/plural, decimals, drop-zero
/// minutes). Numbers above the clip range simply yield missing clips, which makes
/// `ClipVoiceCoach` fall back to the system voice for that cue.
enum VoiceScript {

    static func sentence(for cue: VoiceCue) -> String {
        tokens(for: cue).map(\.text).joined()
            .replacingOccurrences(of: " .", with: ".")
            .trimmingCharacters(in: .whitespaces)
    }

    static func tokens(for cue: VoiceCue) -> [VoiceToken] {
        switch cue {
        case .go:
            return [w("go", "Go")]

        case let .mark(unit, type, index, elapsed, meters):
            var t: [VoiceToken] = [
                w(unit == .metric ? "km_mark" : "mi_mark", unit == .metric ? "Kilometer" : "Mile"),
                n(index), brk(),
                w("time", "Time")
            ]
            t += duration(elapsed)
            t.append(brk())
            if type == .ride {
                t.append(w("avg_speed", "Average speed")); t += speed(seconds: elapsed, meters: meters, unit)
            } else {
                t.append(w("avg_pace", "Average pace")); t += pace(seconds: elapsed, meters: meters, unit)
            }
            return t

        case let .goalReached(kind, target, unit, mi):
            var t: [VoiceToken] = [line("goal_\(mi)", Motivation.goalLines[mi]), VoiceToken(clipID: nil, text: " ")]
            switch kind {
            case .distance: t += distance(target, unit)
            case .time:     t += duration(target)
            case .none:     break
            }
            t.append(w("reached", "reached"))
            return t

        case let .finish(type, unit, meters, seconds, mi):
            var t: [VoiceToken] = [activity(type), w("complete", "complete"), brk()]
            if meters > 50 {
                t += distance(meters, unit)
                t.append(w("in", "in")); t += duration(seconds); t.append(brk())
                if type == .ride {
                    t.append(w("avg_speed", "Average speed")); t += speed(seconds: seconds, meters: meters, unit)
                } else {
                    t.append(w("avg_pace", "Average pace")); t += pace(seconds: seconds, meters: meters, unit)
                }
                t.append(brk())
            } else {
                t += duration(seconds); t.append(brk())
            }
            t.append(line("finish_\(mi)", Motivation.finishLines[mi]))
            return t

        case .sample:
            return [line("sample", "Kilometer three. Nice work — you're flying.")]
        }
    }

    // MARK: Building blocks

    private static func n(_ v: Int) -> VoiceToken { VoiceToken(clipID: "n_\(v)", text: "\(v) ") }
    private static func w(_ id: String, _ t: String) -> VoiceToken { VoiceToken(clipID: id, text: t + " ") }
    private static func line(_ id: String, _ t: String) -> VoiceToken { VoiceToken(clipID: id, text: t) }
    private static func brk() -> VoiceToken { VoiceToken(clipID: nil, text: ". ") }

    private static func activity(_ type: ActivityType) -> VoiceToken {
        switch type {
        case .walk: return w("walk", "Walk")
        case .run:  return w("run", "Run")
        case .ride: return w("ride", "Ride")
        }
    }

    private static func duration(_ seconds: TimeInterval) -> [VoiceToken] {
        let total = max(0, Int(seconds)), m = total / 60, s = total % 60
        var t: [VoiceToken] = []
        if m > 0 { t += [n(m), w(m == 1 ? "minute" : "minutes", m == 1 ? "minute" : "minutes")] }
        if s > 0 || m == 0 { t += [n(s), w(s == 1 ? "second" : "seconds", s == 1 ? "second" : "seconds")] }
        return t
    }

    private static func decimal(_ value: Double) -> [VoiceToken] {
        let r = (value * 10).rounded()
        let whole = Int(r) / 10, tenth = Int(r) % 10
        var t = [n(whole)]
        if tenth != 0 { t += [w("point", "point"), n(tenth)] }
        return t
    }

    private static func distance(_ meters: Double, _ unit: UnitSystem) -> [VoiceToken] {
        let v = unit.distance(meters)
        let singular = (v * 10).rounded() == 10
        var t = decimal(v)
        let id = unit == .metric ? (singular ? "km_singular" : "km_plural") : (singular ? "mi_singular" : "mi_plural")
        t.append(w(id, unit == .metric ? (singular ? "kilometer" : "kilometers") : (singular ? "mile" : "miles")))
        return t
    }

    private static func pace(seconds: TimeInterval, meters: Double, _ unit: UnitSystem) -> [VoiceToken] {
        let d = unit.distance(meters)
        guard d > 0.01, seconds > 0 else { return [w("unavailable", "pace unavailable")] }
        let per = Int((seconds / d).rounded()), m = per / 60, s = per % 60
        var t: [VoiceToken] = []
        if m > 0 { t += [n(m), w(m == 1 ? "minute" : "minutes", m == 1 ? "minute" : "minutes")] }
        t += [n(s), w(s == 1 ? "second" : "seconds", s == 1 ? "second" : "seconds")]
        t.append(w(unit == .metric ? "per_km" : "per_mi", unit == .metric ? "per kilometer" : "per mile"))
        return t
    }

    private static func speed(seconds: TimeInterval, meters: Double, _ unit: UnitSystem) -> [VoiceToken] {
        guard seconds > 0, meters > 0 else { return [w("unavailable", "speed unavailable")] }
        var t = decimal(unit.distance(meters) / (seconds / 3600))
        t.append(w(unit == .metric ? "kmh" : "mph", unit == .metric ? "kilometers per hour" : "miles per hour"))
        return t
    }
}

/// Randomized motivation lines (indexed so the system and clip coaches agree).
enum Motivation {
    static let goalLines = [
        "Goal smashed! Outstanding.",
        "You did it — that's a win.",
        "Target hit. Unstoppable today.",
        "Boom. Goal complete.",
        "That's the one. Brilliant work.",
        "Winged it all the way. Superb.",
    ]
    static let finishLines = [
        "Strong finish — be proud of that one.",
        "Nice work out there. Every step counted.",
        "That's how it's done. Recover well.",
        "Great effort. Mercury would be proud.",
        "You showed up and crushed it.",
        "Another one in the bank. Keep building.",
        "Legs of the gods today. Well run.",
    ]
    static func goalIndex() -> Int { Int.random(in: goalLines.indices) }
    static func finishIndex() -> Int { Int.random(in: finishLines.indices) }
}
