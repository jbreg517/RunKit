import Foundation
import AVFoundation

/// Shared audio session config: ducks other audio while we speak; works
/// screen-locked because the target declares the `audio` background mode.
enum RKAudioSession {
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio,
                           options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? s.setActive(true)
    }
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Coach backed by the system speech synthesizer. Always available; also the
/// fallback for `ClipVoiceCoach`. Picks the best installed voice for the chosen
/// accent + gender (honoring gender strictly), preferring enhanced/premium quality.
final class SystemVoiceCoach: NSObject, VoiceCoach, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var releaseWhenIdle = false

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: VoiceCoach

    func speak(_ cue: VoiceCue)      { announce(VoiceScript.sentence(for: cue), final: false) }
    func speakFinal(_ cue: VoiceCue) { announce(VoiceScript.sentence(for: cue), final: true) }
    func stop() {
        releaseWhenIdle = false
        synth.stopSpeaking(at: .immediate)
        RKAudioSession.deactivate()
    }

    private func announce(_ text: String, final: Bool) {
        RKAudioSession.activate()
        let u = AVSpeechUtterance(string: text)
        u.voice = resolvedVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.postUtteranceDelay = 0.1
        releaseWhenIdle = final
        synth.speak(u)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if releaseWhenIdle && !synthesizer.isSpeaking {
            releaseWhenIdle = false
            RKAudioSession.deactivate()
        }
    }

    // MARK: Voice selection

    private var accent: VoiceAccent {
        VoiceAccent(rawValue: UserDefaults.standard.string(forKey: "voiceAccent") ?? "") ?? .british
    }
    private var gender: VoiceGender {
        VoiceGender(rawValue: UserDefaults.standard.string(forKey: "voiceGender") ?? "") ?? .female
    }

    /// Best voice for accent + gender. Gender is honored strictly; if the accent
    /// has no installed voice of that gender, keep the gender and fall back to
    /// another English accent, then the system default.
    func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let want = gender.av
        let lang = accent.languageCode
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func best(_ vs: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
            vs.sorted { $0.quality.rawValue > $1.quality.rawValue }.first
        }
        return best(english.filter { $0.language == lang && effectiveGender($0) == want })
            ?? best(english.filter { effectiveGender($0) == want })
            ?? best(english.filter { $0.language == lang })
            ?? AVSpeechSynthesisVoice(language: lang)
    }

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

    var resolvedVoiceDescription: String {
        guard let v = resolvedVoice() else { return "System default" }
        let tier = v.quality == .premium ? "premium" : (v.quality == .enhanced ? "enhanced" : "compact")
        return "\(v.name) · \(tier)"
    }
}
