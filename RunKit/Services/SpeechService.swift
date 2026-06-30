import Foundation
import AVFoundation

/// Accent options — three English locales for the system voice.
enum VoiceAccent: String, CaseIterable, Identifiable {
    case american, british, australian
    var id: String { rawValue }
    var label: String {
        switch self {
        case .american:   return "American"
        case .british:    return "British"
        case .australian: return "Australian"
        }
    }
    var flag: String {
        switch self {
        case .american:   return "🇺🇸"
        case .british:    return "🇬🇧"
        case .australian: return "🇦🇺"
        }
    }
    var languageCode: String {
        switch self {
        case .american:   return "en-US"
        case .british:    return "en-GB"
        case .australian: return "en-AU"
        }
    }
}

enum VoiceGender: String, CaseIterable, Identifiable {
    case female, male
    var id: String { rawValue }
    var label: String { self == .female ? "Female" : "Male" }
    var av: AVSpeechSynthesisVoiceGender { self == .female ? .female : .male }
}

/// Which coach speaks: the bundled natural-voice pack or the system synthesizer.
enum CoachStyle: String, CaseIterable, Identifiable {
    case natural, system
    var id: String { rawValue }
    var label: String { self == .natural ? "Natural" : "System" }
}

/// Facade over the voice coaches. Routes cues to the bundled natural-voice pack
/// when selected (it falls back to the system voice per cue until the pack ships),
/// otherwise the system synthesizer. On-device, no network.
final class SpeechService {
    static let shared = SpeechService()
    private let systemCoach = SystemVoiceCoach()
    private lazy var clipCoach = ClipVoiceCoach(fallback: systemCoach)

    private var style: CoachStyle {
        CoachStyle(rawValue: UserDefaults.standard.string(forKey: "coachStyle") ?? "") ?? .system
    }
    private var coach: VoiceCoach { style == .natural ? clipCoach : systemCoach }

    func speak(_ cue: VoiceCue)      { coach.speak(cue) }
    func speakFinal(_ cue: VoiceCue) { coach.speakFinal(cue) }
    func stop()                      { coach.stop() }
    func preview()                   { coach.speakFinal(.sample) }

    /// For Settings.
    var resolvedVoiceDescription: String { systemCoach.resolvedVoiceDescription }
    var naturalPackInstalled: Bool { clipCoach.isPackInstalled }
}
