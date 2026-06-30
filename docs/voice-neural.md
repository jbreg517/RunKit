# RunKit — Reaching Google-Assistant-class voice (on-device neural TTS)

> The path beyond option B. Concatenative clips plateau at "good"; full
> human-likeness needs **end-to-end neural synthesis of each utterance**. The goal
> is to do that **on the device** so the privacy promise (no runtime network,
> "Data Not Collected") is untouched.
>
> **Status: app-side scaffolding shipped in v0.12.** `NeuralVoiceCoach` +
> `NeuralTTSEngine`/`CoreMLNeuralTTSEngine` are in, and the facade prefers neural →
> clip pack → system under the "Natural" option. The model + Core ML conversion +
> G2P remain (Mac-side) — see [../tools/voicemodel/README.md](../tools/voicemodel/README.md).

## ⚠️ Do you even need this? (Usually not)
On-device real-time neural synthesis is only required to speak **arbitrary text
not known until runtime**. RunKit's announcements are a **fixed, non-responsive
comment set**, so you can pre-generate the audio offline with a great neural voice
and ship files — **no Mac, no Core ML** (see
[voice-cue-pack.md](voice-cue-pack.md) / [../tools/voicecues/](../tools/voicecues/)).
That gets ~8/10 with far less work. This neural-on-device path only pays off if you
later want to speak unbounded/dynamic text live (e.g. a coach that reacts to your
splits in real time). The scaffolding below stays dormant until then.

## Why this, not more of option B
Google Assistant generates the whole sentence with one neural model → continuous,
contextual prosody. Concatenated clips glue fragments → pitch/rhythm break at every
number. B is great for shipping now with zero dependencies, but its naturalness
ceiling is ~6.5–7.5/10. Neural full-utterance synthesis is ~8.5–9/10.

## It drops into the architecture we already built
`VoiceCoach` already abstracts the engine, and `VoiceScript.sentence(for: cue)`
already produces the exact text. A neural coach is essentially:

```
final class NeuralVoiceCoach: VoiceCoach {
    func speak(_ cue) { synthesize(VoiceScript.sentence(for: cue)) }   // → PCM → AVAudioEngine
    ...
}
```

So the work is **the model + runtime + text front-end**, not RunKit plumbing.

## The three real pieces
1. **Model** (permissive license required to ship):
   - **Kokoro-82M** — Apache-2.0, tiny, surprisingly natural, several voices. Strong
     first candidate.
   - **Piper** (VITS) — MIT, very light (~20–60 MB/voice), runs on a Pi; good, not
     SOTA. Note its espeak-ng front-end is GPL (see #3).
   - **StyleTTS2 / Parler-TTS / MeloTTS / Chatterbox** — MIT/Apache, higher quality,
     heavier. **Avoid Coqui XTTS** (non-commercial-ish CPML license).
2. **Runtime on iOS:** convert to **Core ML** (`coremltools`) to run on the Apple
   Neural Engine (faster-than-realtime on A-series, low battery), or bundle **ONNX
   Runtime**. Output PCM → play through the same `AVAudioEngine`/ducked session we
   already have.
3. **Text front-end (G2P):** most TTS need grapheme→phoneme. Watch licensing —
   espeak-ng is GPL (bad for bundling); prefer a model whose front-end is permissive
   (Kokoro uses *misaki*). This is the easiest part to get wrong.

## Budget / tradeoffs
- **App size:** +~20–80 MB per voice (quantized). Could ship via On-Demand
  Resources to keep the base app slim.
- **Latency:** announcements are infrequent (every km) and not real-time, so even
  200–500 ms synth is invisible; these models run < realtime on-device anyway.
- **Battery:** one short inference per km → negligible.
- **Build tooling:** Core ML conversion + quantization needs a **Mac** (and the
  model assets) — can't be done from the current Windows box.

## A distinctive, privacy-perfect alt: Personal Voice (iOS 17+)
Apps can use the user's **Personal Voice** with permission
(`AVSpeechSynthesizer.requestPersonalVoiceAuthorization`) — an on-device neural
clone, fully private. It won't sound like Google Assistant (it sounds like *you*),
but it's natural/neural, on-brand for a privacy-first app, and far less work than
bundling a model. Worth offering as a "coach in my own voice" option regardless.

## The disqualified option (for completeness)
Runtime cloud TTS (Google/ElevenLabs/Azure) hits 10/10 trivially. The only data
sent is innocuous announcement text ("Kilometer 3…"), no location/PII — so it
*could* be an explicit, off-by-default opt-in ("Premium cloud voice"). But it
changes the App Store privacy label and the brand promise; keep it off the
default path.

## Recommendation
- **Endgame:** add a `NeuralVoiceCoach` backed by Kokoro-class on-device neural TTS
  (Core ML / ANE). This supersedes the option-B clip pack for the "great" bar —
  if we commit to neural, B2 (recording/generating the clip pack) becomes optional.
- **Cheap interim (ships now, no model):** bias `SystemVoiceCoach` to *premium*
  voices and nudge the user to install one; optionally add Personal Voice support.
- **Reality check:** the neural path is a real project (model selection, Core ML
  conversion on a Mac, G2P licensing, ~tens of MB, on-device testing). The
  Windows dev box can't do the model/Core ML steps — that part needs the Mac.

## Phasing if we go neural
- **N0:** pick the model + voice; confirm license; prototype synth → WAV on a Mac.
- **N1:** Core ML convert + quantize; measure size/latency on a device.
- **N2:** `NeuralVoiceCoach` (Core ML inference → PCM → `AVAudioEngine`) behind the
  existing "Coach voice" picker (add a "Natural (neural)" option); fall back to
  `SystemVoiceCoach` if the model/ANE is unavailable.
- **N3:** tune prosody, ship one persona, consider On-Demand Resources.
