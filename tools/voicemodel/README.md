# Neural voice model — integration (Mac side)

The app-side scaffolding is in place ([NeuralVoiceCoach.swift](../../RunKit/Services/NeuralVoiceCoach.swift)):
`NeuralVoiceCoach` synthesizes the full sentence (`VoiceScript.sentence(for: cue)`),
plays it through the shared ducked `AVAudioEngine`, and **falls back to the system
voice whenever the model or inference isn't ready** — so the app is unchanged until
the model lands. What's left is model + Core ML + the grapheme→phoneme front-end,
which all need a **Mac** (and can't be done from the Windows dev box). See
[../../docs/voice-neural.md](../../docs/voice-neural.md) for rationale.

## The contract the app expects
- **Model file:** add `RunKitTTS.mlpackage` to `RunKit/Resources/VoiceModel/` and
  `xcodegen generate`. Xcode compiles it to `RunKitTTS.mlmodelc` in the bundle;
  `CoreMLNeuralTTSEngine` loads it by that name and flips `isReady` true.
- **Inference:** fill in `CoreMLNeuralTTSEngine.synthesize(_:)` — the single TODO:
  `text → phonemes → token MLMultiArray → model.prediction(...) → waveform
  MLMultiArray → AVAudioPCMBuffer` (mono, model sample rate, e.g. 24 kHz). Return
  nil on any failure (keeps the system fallback).
- Routing already prefers neural when `isAvailable` (see `SpeechService.coach`).
  No Settings change needed — it surfaces under the existing **Natural** option.

## Steps
- **N0 — pick & license:** choose a permissive model + a pleasant voice. Candidates:
  **Kokoro-82M** (Apache-2.0, tiny, natural; misaki G2P), **Piper** (MIT, light;
  but espeak-ng G2P is GPL — avoid bundling that front-end), StyleTTS2/Parler/
  MeloTTS/Chatterbox. **Avoid Coqui XTTS** (non-commercial CPML). Confirm the model
  *and its G2P* are OK to ship.
- **N1 — convert:** `coremltools` → `.mlpackage`; quantize (int8/fp16) for size +
  Apple Neural Engine. Measure size (~20–80 MB) and per-utterance latency on a
  device (target < a few hundred ms; ours isn't real-time anyway).
- **N2 — G2P + inference:** port the front-end (phonemizer) to Swift or bundle a
  permissive one; wire `synthesize(_:)`.
- **N3 — polish:** prosody/loudness, one persona, consider On-Demand Resources to
  keep the base app slim. Optionally make **Natural** the default `coachStyle`.

## Privacy
All inference is on-device; no runtime network. The App Store "Data Not Collected"
label is unaffected.
