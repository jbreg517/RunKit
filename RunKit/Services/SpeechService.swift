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

    /// Resolves the best voice for the chosen accent + gender. Gender is honored
    /// **strictly** — a wrong-gender voice is never returned. If the requested
    /// accent has no voice of that gender installed, we keep the gender and fall
    /// back to another English accent (and Settings nudges the user to download the
    /// matching voice). Within each tier we prefer the highest quality, so a
    /// downloaded enhanced/premium voice wins over the robotic compact one.
    func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let want = gender.av
        let lang = accent.languageCode
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func best(_ vs: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
            vs.sorted { $0.quality.rawValue > $1.quality.rawValue }.first
        }
        return best(english.filter { $0.language == lang && effectiveGender($0) == want }) // accent + gender
            ?? best(english.filter { effectiveGender($0) == want })                        // gender, any accent
            ?? best(english.filter { $0.language == lang })                                 // accent, any gender
            ?? AVSpeechSynthesisVoice(language: lang)                                        // system default
    }

    /// `AVSpeechSynthesisVoice.gender` is often `.unspecified` for bundled voices,
    /// so disambiguate the well-known ones by name.
    private func effectiveGender(_ v: AVSpeechSynthesisVoice) -> AVSpeechSynthesisVoiceGender {
        if v.gender != .unspecified { return v.gender }
        let name = v.name.lowercased()
        if Self.maleNames.contains(where: { name.contains($0) }) { return .male }
        if Self.femaleNames.contains(where: { name.contains($0) }) { return .female }
        return .unspecified
    }

    private static let femaleNames = ["samantha", "martha", "kate", "serena", "stephanie", "fiona",
        "moira", "tessa", "karen", "catherine", "allison", "ava", "susan", "zoe", "nicky", "joelle", "sandy"]
    private static let maleNames = ["daniel", "arthur", "oliver", "aaron", "fred", "albert", "junior",
        "lee", "gordon", "rishi", "tom", "reed", "ralph", "rocko"]

    /// What voice will actually be used, for display in Settings — so it's obvious
    /// when the chosen accent/gender isn't installed (still robotic = compact).
    var resolvedVoiceDescription: String {
        guard let v = resolvedVoice() else { return "System default" }
        let tier = v.quality == .premium ? "premium" : (v.quality == .enhanced ? "enhanced" : "compact")
        return "\(v.name) · \(tier)"
    }

    private func beginAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = resolvedVoice()
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
