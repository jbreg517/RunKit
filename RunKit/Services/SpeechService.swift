import Foundation
import AVFoundation

/// Spoken pace/distance feedback via the system speech synthesizer. Ducks other
/// audio (music, podcasts) while it speaks. On-device, no network. Works with the
/// screen locked because the target declares the `audio` background mode.
final class SpeechService {
    static let shared = SpeechService()
    private let synth = AVSpeechSynthesizer()

    /// Activate a playback audio session that ducks other audio while we speak.
    private func beginAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
    }

    func announce(_ text: String) {
        beginAudio()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        synth.speak(utterance)
    }

    /// Stop speaking and release the audio session so other audio resumes.
    func endAudio() {
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
