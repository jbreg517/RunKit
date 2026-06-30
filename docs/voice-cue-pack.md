# RunKit — Natural Voice Cue Pack (design)

> Option B from the voice research: replace robotic on-device TTS with
> **pre-rendered audio clips** played back and stitched at runtime. Fully
> on-device, no runtime network → keeps the privacy promise. Status: **design /
> not built.** System `AVSpeechSynthesizer` ([SpeechService](../RunKit/Services/SpeechService.swift))
> stays as the fallback.

## Goal
A signature, genuinely human-sounding coach that never depends on which system
voices the user has downloaded — the way Garmin / Runkeeper / Nike audio cues
work. Compact `AVSpeechSynthesisVoice` is the robotic culprit; bundling real
audio sidesteps it entirely.

## Architecture — a `VoiceCoach` behind structured cues
Today announcements are built as **strings** in `ActivitySessionView` and handed
to `SpeechService`. For clips we can't post-process a finished sentence, so we
pass **structured cues** instead and let each coach render them:

```
enum VoiceCue {
    case go
    case mark(unit: UnitSystem, index: Int, elapsed: TimeInterval,
              avgPaceOrSpeed: PaceOrSpeed)        // "Kilometer 3. Time … Average pace …"
    case goalReached(GoalKind, target: Double, unit: UnitSystem, motivation: String)
    case finish(type: ActivityType, meters: Double, seconds: Double,
                unit: UnitSystem, motivation: String)
    case sample
}

protocol VoiceCoach {
    func speak(_ cue: VoiceCue)        // mid-session (keeps audio session active)
    func speakFinal(_ cue: VoiceCue)   // releases the audio session when done
    func stop()
}
```

- `SystemVoiceCoach` — wraps the current synthesizer; renders a cue to a string
  via the existing spoken helpers (`UnitSystem.spokenPace`, etc.). This is the
  **fallback** and covers accents/values we don't ship clips for.
- `ClipVoiceCoach` — maps a cue to a **sequence of clip IDs** and plays them.

`ActivitySessionView` only ever emits `VoiceCue`s; a settings choice selects the
coach. This refactor (strings → cues) is the bulk of Phase B1 and is worth doing
regardless.

## Clip inventory (per voice persona)
Bounded and small — concatenate building blocks rather than pre-rendering every
sentence:

- **Cardinals 0–99** (rendered in a neutral, non-final tone) — ~100 clips.
- **Units / connectives:** `point`, `minute`/`minutes`, `second`/`seconds`,
  `kilometer`/`kilometers`/`per kilometer`, `mile`/`miles`/`per mile`,
  `Time`, `Average pace`, `Average speed`, `in`, `reached`, `complete`, `Go`.
- **Activity nouns:** `Walk`, `Run`, `Ride`.
- **Whole phrases:** the 6 goal-reached + 7 finish motivation lines (recorded
  whole, so they carry real intonation).

≈150–180 clips × ~0.3–1.0 s, AAC mono ~22 kHz ≈ **1–3 MB per persona**. Bundle in
`Resources/VoiceCues/<persona>/` with a JSON manifest (`id → text`, for
regeneration + the system-voice fallback string).

### Sequencing rules
- Distance: `{whole} point {tenth} kilometers`; drop the decimal when `.0`
  ("5 kilometers"). Use **singular** units for 1 ("1 minute", "Kilometer 1").
- Pace: drop a leading "0 minutes" ("45 seconds per kilometer").
- **Range guard:** any value > 99 (ultra-long session, etc.) → fall back to the
  system coach for that one cue. No clip gaps to maintain.
- Gaps: ~60–120 ms between clips, longer at sentence ends, for natural rhythm.

## Playback
`AVAudioEngine` + a single `AVAudioPlayerNode`, `scheduleBuffer` the clip buffers
back-to-back (they queue gaplessly). Reuse today's `.playback`/`.duckOthers`
audio session + the `audio` background mode, so it still ducks music and works
screen-locked. Decode the few needed clips lazily and cache the PCM buffers
(announcements are infrequent — every km — so memory stays tiny).

## How the audio gets made (build-time only — never at runtime)
A dev-machine script renders the manifest → audio once, then we ship the files:
1. Read `manifest.json` (`id → text`).
2. Render each line with the chosen voice (see decision below).
3. Normalize loudness (~-16 LUFS), trim/standardize leading/trailing silence,
   short fades, encode AAC mono.
4. Emit to `Resources/VoiceCues/<persona>/`.

No network at runtime → the App Store "Data Not Collected" label is unaffected.
(Note: this machine has Node but **no ffmpeg** for the audio post-processing —
do the render/encode step on a box with ffmpeg, or trim/normalize in-app at load.)

## Voice source (the key decision)
- **Neural TTS, generated offline** (ElevenLabs / Azure Neural / Polly / Play.ht):
  fast, cheap, repeatable, very natural. **Must confirm the provider's license
  permits redistributing the generated audio inside a shipped app** (ElevenLabs
  paid + Azure/Polly commercial terms generally do — verify current terms).
- **Human voice actor:** most authentic; costs money + a re-record to change
  lines; get an app-distribution buyout.
- **Avoid** shipping Apple `say`/`AVSpeech` output (redistribution rights unclear)
  and **any runtime cloud TTS** (breaks the privacy promise).

## Personas vs the existing accent/gender pickers
Shipping clip packs for all 6 accent×gender combos is a lot of audio. Recommend:
add a top-level **"Coach voice: Natural (RunKit) · System"** choice. *Natural* =
1–2 bundled personas (e.g. one female, one male); *System* = today's
accent/gender `AVSpeech` pickers (kept as-is and as the fallback).

## Phasing
- **B1 — plumbing (no final audio):** add `VoiceCue` + `VoiceCoach`, refactor
  `ActivitySessionView` to emit cues, build `ClipVoiceCoach` + the
  `AVAudioEngine` player + manifest/sequencer, and prove it end-to-end with a
  **throwaway placeholder pack** (e.g. generated with a free voice). Settings
  toggle. ~the real engineering.
- **B2 — final voice:** drop in the licensed natural-voice pack(s), tune
  loudness/gaps, add the second persona. Mostly content + polish.

This de-risks: build and test the machinery first, swap in the good audio later.

## App size & distribution
1–3 MB per persona bundled. Could move to On-Demand Resources later to keep the
base app slim, but bundling is simplest and keeps everything offline for v1.
