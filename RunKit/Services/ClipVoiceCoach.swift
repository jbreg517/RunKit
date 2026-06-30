import Foundation
import AVFoundation

/// Coach that plays a bundled human-voice audio pack, stitching clips for the
/// dynamic parts (numbers, units). If ANY required clip is missing it defers the
/// whole cue to the system voice, so a clean sentence is always spoken — which is
/// also why this degrades gracefully until the B2 audio pack ships.
///
/// Clips live in the app bundle as `<id>.m4a` (optionally under a `VoiceCues`
/// folder), generated offline from `tools/voicecues/manifest.json`. See
/// docs/voice-cue-pack.md.
final class ClipVoiceCoach: NSObject, VoiceCoach {
    private let fallback: SystemVoiceCoach
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var releaseWhenIdle = false

    init(fallback: SystemVoiceCoach) {
        self.fallback = fallback
        super.init()
        engine.attach(player)
    }

    /// True once at least the number clips are present (sentinel check).
    var isPackInstalled: Bool { clipURL("n_0") != nil }

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
        let needed = VoiceScript.tokens(for: cue).compactMap(\.clipID)
        let buffers = needed.compactMap(buffer(for:))
        // Missing any clip → one clean spoken sentence instead of a patchwork.
        guard !needed.isEmpty, buffers.count == needed.count, let first = buffers.first else {
            final ? fallback.speakFinal(cue) : fallback.speak(cue)
            return
        }
        guard prepareEngine(format: first.format) else {
            final ? fallback.speakFinal(cue) : fallback.speak(cue)
            return
        }
        RKAudioSession.activate()
        releaseWhenIdle = final
        player.stop()
        for (i, buf) in buffers.enumerated() {
            let isLast = i == buffers.count - 1
            player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
                if isLast { self?.handleQueueFinished() }
            }
        }
        player.play()
    }

    private func handleQueueFinished() {
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

    // MARK: Clip loading

    private func clipURL(_ id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "m4a", subdirectory: "VoiceCues")
            ?? Bundle.main.url(forResource: id, withExtension: "m4a")
    }

    private func buffer(for id: String) -> AVAudioPCMBuffer? {
        guard let url = clipURL(id),
              let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        return buf
    }
}
