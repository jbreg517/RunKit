# Natural voice cue pack — generation (no Mac needed)

RunKit's announcements are a **fixed, non-responsive comment set**, so the audio is
generated **once, offline**, and shipped as files — the app never runs a model.
That means **no Mac and no Core ML**: a neural TTS runs locally on Windows (or use a
build-time cloud API), and `ffmpeg` is cross-platform. The app side
([ClipVoiceCoach](../../RunKit/Services/ClipVoiceCoach.swift)) just plays
`<id>.m4a` clips. Design: [../../docs/voice-cue-pack.md](../../docs/voice-cue-pack.md).

## Steps
1. **Manifest** — `node build-manifest.js` writes `manifest.json` (`id → text`,
   140 clips). Numbers 0–99 are spelled out ("forty-two") so the TTS says them
   naturally; clip IDs stay `n_<value>`. Keep the phrase lines in sync with
   `Motivation` in `RunKit/Services/VoiceCue.swift`.
2. **Generate** — `python generate.py` renders every line, trims/normalizes, and
   encodes mono AAC `.m4a` into `out/`. Defaults to **Kokoro** (Apache-2.0,
   on-device-class, pip-installable); pick the voice with `RK_VOICE` (e.g.
   `bf_emma` British female, `am_adam` American male). Swap the `synthesize()`
   function for any other model or a cloud API.
   ```
   pip install kokoro soundfile numpy
   winget install Gyan.FFmpeg      # or choco install ffmpeg
   RK_VOICE=bf_emma python generate.py
   ```
3. **Bundle** — copy `out/*.m4a` into `RunKit/Resources/VoiceCues/` and
   `xcodegen generate`. `ClipVoiceCoach` finds them by id, `isPackInstalled`
   flips true, and "Natural" in Settings starts using them. Flip the default
   `coachStyle` to `natural` once you're happy.

## Making it sound "contextualized" (natural prosody)
Assembled clips can sound choppy at number boundaries. Levers, cheapest first:
- **Good neural voice + whole connective clips** (we render `per kilometer`,
  `Average pace`, etc. as whole clips) — gets most of the way.
- **Positional number variants** — render a phrase-final, falling-tone variant of
  each number for spots like "Kilometer 3." Generate `n_<v>_f` from the text
  "<word>." (trailing period) and have `VoiceScript` request `_f` at phrase ends.
  Not wired yet — add if single-variant isn't natural enough.
- **Loudness match** — peak-normalize here; for tighter consistency use LUFS
  (`pip install pyloudnorm`).

## Notes
- Until the pack ships, **Natural** transparently falls back to the system voice.
- ~1–3 MB total. On-device real-time neural (Core ML, needs a Mac) is **not**
  required for this fixed comment set — see [../../docs/voice-neural.md](../../docs/voice-neural.md).
