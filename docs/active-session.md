# RunKit — Active Session (run page)

> The live recording screen (`ActivitySessionView`). Built up over v0.07.

## Setup
- Type (walk / run / ride), GPS toggle, and an optional **goal**: None / Distance
  / Time. Distance is entered in the current unit; time in minutes.
- **Start** runs a 3-2-1 countdown (overlay) before the timer and tracking begin,
  so you can pocket the phone. A short "Go" is spoken if voice is on.

## Live
- **Collapsible map** (GPS sessions only) — the route so far + the current
  position (system blue dot), camera following you. Tap the header to collapse it
  and keep the timer glanceable.
- **Timer** (big, monospaced) + three metrics:
  - **Distance**
  - **Current pace/speed** — smoothed over a rolling 20 s window in
    `LocationService.currentSpeedMps`, and the readout is refreshed **every 3 s**
    (raw GPS speed is too jumpy to show live). Rides show speed; walk/run show pace.
  - **Average pace/speed** — elapsed ÷ distance.
- **Goal progress** bar when a goal was set.

## Voice coaching (`SpeechService`)
- Announces each completed **kilometer/mile** ("Kilometer 3. Time 18 minutes 42
  seconds. Average pace 6 minutes 14 seconds per kilometer."), a **motivational
  line** on goal-reached, and a **spoken finish recap** (distance, time, avg
  pace/speed) with a motivational sign-off (`Motivation` lines, randomized).
- **Choosable voice (v0.08):** accent — 🇺🇸 American / 🇬🇧 British / 🇦🇺 Australian
  (`en-US`/`en-GB`/`en-AU`) — and gender (female/male). Picks the highest-quality
  *installed* voice for that locale+gender (enhanced/premium if downloaded), with
  fallbacks. Defaults to British female. Settings has a **Preview voice** button.
- Uses `AVSpeechSynthesizer` with a `.playback`/`.duckOthers` audio session, so it
  ducks music and works screen-locked (target declares the `audio` background
  mode). The finish recap uses `announceFinal`, which releases the audio session
  only after speaking finishes (so it isn't cut off). Toggle: Settings ▸ Tracking ▸
  "Voice coaching".

## Finish
- `finalize()` resolves distance (GPS, with pedometer fallback for walk/run — see
  [route-and-session-detail.md](route-and-session-detail.md)), recomputes calories,
  saves to SwiftData, and writes the workout + route to Apple Health.

## Deferred
- Pause/resume; live splits on-screen; per-session unit override; richer
  finish summary (spoken recap).
