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
   pip install kokoro-onnx soundfile imageio-ffmpeg
   # one-time: download the model next to generate.py (gitignored) —
   #   kokoro-v1.0.onnx + voices-v1.0.bin
   #   from github.com/thewh1teagle/kokoro-onnx releases (tag model-files-v1.0)
   RK_VOICE=bf_emma python generate.py
   # PowerShell: $env:RK_VOICE='bf_emma'; python generate.py
   ```
   Uses `kokoro-onnx` (no PyTorch — installs cleanly on modern Python incl. 3.14;
   the torch-based `kokoro` package can't build numpy on 3.14). `imageio-ffmpeg`
   bundles ffmpeg, so no separate ffmpeg install is needed.
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

## Expressive engines (auditioned 2026-06)
Kokoro is flat emotionally. Two shippable expressive alternatives were sampled:
- **Chatterbox** (MIT) — emotion `exaggeration` + `cfg_weight` pacing knobs; voice
  via cloning a reference clip. Samples: `chatterbox_samples.py` (emotion sweep,
  `out/expressive/`), `chatterbox_voices.py` (accents via Kokoro refs from
  `make_refs.py`, `out/voices/`). Venv: torch-based, Python 3.12.
- **Parler-TTS mini v1** (Apache-2.0) — accent + emotion + pace described in a
  natural-language prompt. Samples: `parler_samples.py` (`out/parler/`); interactive
  experimentation: `parler_try.py` (`out/try/`, one-shot or loop, `--seed` for
  repeatability).

### Parler environment (persistent — do NOT put venvs in %TEMP%)
Windows periodically cleans `%TEMP%`, which breaks venvs ("No Python at ...").
The Parler venv lives at `%LOCALAPPDATA%\rk-tts\parler`. Recreate if needed:
```powershell
uv venv "$env:LOCALAPPDATA\rk-tts\parler" --python 3.12
uv pip install --python "$env:LOCALAPPDATA\rk-tts\parler\Scripts\python.exe" `
  "numba>=0.61" "llvmlite>=0.44" hf_transfer `
  "git+https://github.com/huggingface/parler-tts.git" soundfile imageio-ffmpeg
```
(`numba`/`llvmlite` floors avoid a py≤3.9 source build; `hf_transfer` gets the
3.5 GB model past a ~350 MB per-connection download cap seen on this network.)
Run:
```powershell
cd tools\voicecues
& "$env:LOCALAPPDATA\rk-tts\parler\Scripts\python.exe" parler_try.py
```

## Notes
- Until the pack ships, **Natural** transparently falls back to the system voice.
- ~1–3 MB total. On-device real-time neural (Core ML, needs a Mac) is **not**
  required for this fixed comment set — see [../../docs/voice-neural.md](../../docs/voice-neural.md).
