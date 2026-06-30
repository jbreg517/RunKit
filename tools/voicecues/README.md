# Natural voice cue pack — generation (B2)

Build-time pipeline that turns text into the bundled on-device audio pack. This
runs **on a dev machine only**; the app never hits the network at runtime. See
[../../docs/voice-cue-pack.md](../../docs/voice-cue-pack.md) for the design.

## Steps
1. **Manifest** — `node build-manifest.js` writes `manifest.json` (`id → text`),
   140 clips: numbers 0–99, unit/connective words, and the 13 motivation phrases.
   Keep it in sync with `RunKit/Services/VoiceCue.swift` (the `Motivation` arrays
   and the clip IDs in `VoiceScript`).
2. **Render** — for each `id → text`, synthesize `text` with the chosen voice
   (decision: an offline neural TTS — ElevenLabs / Azure Neural / Polly). One
   persona for v1. ⚠️ **Confirm the provider's license permits shipping the
   generated audio inside the app.**
   - Tip: render numbers with a flat/continuing intonation (they sit mid-sentence);
     let the unit/phrase clips carry the sentence-final fall.
3. **Post-process** (needs `ffmpeg` — not on the current Windows box; run on a Mac
   or a box with ffmpeg): trim leading/trailing silence consistently, normalize
   loudness (~-16 LUFS), tiny fades, encode **mono AAC `.m4a`, one sample rate for
   all clips** (the player connects one format). Name each file `<id>.m4a`.
4. **Bundle** — drop the `.m4a` files into `RunKit/Resources/VoiceCues/` and run
   `xcodegen generate`. `ClipVoiceCoach` looks them up by id (with or without the
   `VoiceCues` subdirectory) and lights up automatically; `isPackInstalled`
   flips true. Flip the default `coachStyle` to `natural` once the pack ships.

## Notes
- Until the pack is present, selecting **Natural** in Settings transparently falls
  back to the **System** voice per cue — no broken/partial audio.
- ~1–3 MB for the pack. If app size matters later, move it to On-Demand Resources.
