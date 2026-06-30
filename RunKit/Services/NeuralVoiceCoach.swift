import Foundation
import AVFoundation
import CoreML

/// On-device neural text-to-speech. The Core ML implementation is wired on a Mac
/// (model conversion + G2P) — see tools/voicemodel/README.md. Until a model is
/// bundled, `isReady` is false and the coach falls back to the system voice.
protocol NeuralTTSEngine: AnyObject {
    var isReady: Bool { get }
    /// Synthesize text to a mono PCM buffer at the model's sample rate, or nil.
    func synthesize(_ text: String) -> AVAudioPCMBuffer?
}

/// Loads a bundled compiled Core ML model (`RunKitTTS.mlmodelc`, produced by Xcode
/// from the `.mlpackage`) and runs full-utterance synthesis. The inference body is
/// the only piece left for the Mac-side work; everything around it is in place.
final class CoreMLNeuralTTSEngine: NeuralTTSEngine {
    private let model: MLModel?

    init() {
        if let url = Bundle.main.url(forResource: "RunKitTTS", withExtension: "mlmodelc") {
            model = try? MLModel(contentsOf: url)
        } else {
            model = nil
        }
    }

    var isReady: Bool { model != nil }

    func synthesize(_ text: String) -> AVAudioPCMBuffer? {
        guard let model else { return nil }
        _ = model
        // TODO (Mac, N2): grapheme→phoneme(text) → token MLMultiArray → model
        // prediction → waveform MLMultiArray → copy into an AVAudioPCMBuffer at the
        // model's sample rate (e.g. 24 kHz mono). Returns nil until wired, which
        // keeps the coach on its system fallback.
        return nil
    }
}

/// Coach backed by on-device neural TTS. Synthesizes the full sentence
/// (`VoiceScript.sentence`) end-to-end — the path to Google-Assistant-class
/// prosody while staying on-device. Falls back to the system voice per cue
/// whenever the model/inference is unavailable.
final class NeuralVoiceCoach: NSObject, VoiceCoach {
    private let fallback: SystemVoiceCoach
    private let tts: NeuralTTSEngine
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var releaseWhenIdle = false

    init(fallback: SystemVoiceCoach, tts: NeuralTTSEngine = CoreMLNeuralTTSEngine()) {
        self.fallback = fallback
        self.tts = tts
        super.init()
        engine.attach(player)
    }

    /// True once a usable model is loaded — used by the facade to prefer this coach.
    var isAvailable: Bool { tts.isReady }

    // MARK: VoiceCoach

    func speak(_ cue: VoiceCue)      { play(cue, final: false) }
    func speakFinal(_ cue: VoiceCue) { play(cue, final: true) }
    func stop() {
        releaseWhenIdle = false
        player.stop()
        engine.stop()
        fallback.stop()
        RKAudioSession.deactivate()
    }

    // MARK: Playback

    private func play(_ cue: VoiceCue, final: Bool) {
        guard let buffer = tts.synthesize(VoiceScript.sentence(for: cue)),
              prepareEngine(format: buffer.format) else {
            final ? fallback.speakFinal(cue) : fallback.speak(cue)
            return
        }
        RKAudioSession.activate()
        releaseWhenIdle = final
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in self?.handleFinished() }
        player.play()
    }

    private func handleFinished() {
        guard releaseWhenIdle else { return }
        releaseWhenIdle = false
        DispatchQueue.main.async { [weak self] in
            self?.engine.stop()
            RKAudioSession.deactivate()
        }
    }

    private func prepareEngine(format: AVAudioFormat) -> Bool {
        if connectedFormat?.isEqual(format) != true {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return true
    }
}
