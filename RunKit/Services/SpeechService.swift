import Foundation
import AVFoundation

/// Accent options — three English locales per voice.
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

/// Randomized motivational lines. The Mercury nods tie back to the icon/theme.
enum Motivation {
    private static let finishLines = [
        "Strong finish — be proud of that one.",
        "Nice work out there. Every step counted.",
        "That's how it's done. Recover well.",
        "Great effort. Mercury would be proud.",
        "You showed up and crushed it.",
        "Another one in the bank. Keep building.",
        "Legs of the gods today. Well run.",
    ]
    private static let goalLines = [
        "Goal smashed! Outstanding.",
        "You did it — that's a win.",
        "Target hit. Unstoppable today.",
        "Boom. Goal complete.",
        "That's the one. Brilliant work.",
        "Winged it all the way. Superb.",
    ]
    static func finish() -> String { finishLines.randomElement() ?? "Well done." }
    static func goal() -> String { goalLines.randomElement() ?? "Goal reached." }
}

/// Spoken pace/distance feedback via the system speech synthesizer. Picks the best
/// installed voice for the chosen accent + gender, ducks other audio while speaking,
/// and works with the screen locked (target declares the `audio` background mode).
/// On-device, no network.
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()
    private let synth = AVSpeechSynthesizer()
    /// When set, the audio session is released once the queue finishes (so an
    /// end-of-run recap isn't cut off the way `endAudio()` would do).
    private var releaseWhenIdle = false

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Preferences (shared store with @AppStorage in Settings)

    private var accent: VoiceAccent {
        VoiceAccent(rawValue: UserDefaults.standard.string(forKey: "voiceAccent") ?? "") ?? .british
    }
    private var gender: VoiceGender {
        VoiceGender(rawValue: UserDefaults.standard.string(forKey: "voiceGender") ?? "") ?? .female
    }

    /// Best installed voice for the chosen accent + gender, preferring higher
    /// quality (enhanced/premium if downloaded), with graceful fallbacks.
    private func voice() -> AVSpeechSynthesisVoice? {
        let lang = accent.languageCode
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        let matched = all.filter { $0.gender == gender.av }
        let pool = matched.isEmpty ? all : matched
        return pool.sorted { $0.quality.rawValue > $1.quality.rawValue }.first
            ?? AVSpeechSynthesisVoice(language: lang)
    }

    private func beginAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.postUtteranceDelay = 0.1
        return u
    }

    /// Speak now (mid-session marks). Keeps the audio session active afterward.
    func announce(_ text: String) {
        releaseWhenIdle = false
        beginAudio()
        synth.speak(utterance(text))
    }

    /// Speak, then release the audio session once finished — for the end-of-run recap.
    func announceFinal(_ text: String) {
        beginAudio()
        synth.speak(utterance(text))
        releaseWhenIdle = true
    }

    /// Short sample so users can hear the selected voice in Settings.
    func preview() {
        announceFinal("Kilometer three. Nice work — you're flying.")
    }

    /// Stop immediately and release the audio session.
    func endAudio() {
        releaseWhenIdle = false
        synth.stopSpeaking(at: .immediate)
        deactivate()
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if releaseWhenIdle && !synthesizer.isSpeaking {
            releaseWhenIdle = false
            deactivate()
        }
    }
}
