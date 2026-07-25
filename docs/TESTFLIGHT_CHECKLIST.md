# RunKit — TestFlight smoke test

> **Purpose:** v0.15–v0.25 were written blind. They compile and ship, but the
> runtime paths below have **never been exercised**. This checklist targets
> exactly that code — it is not generic QA.
>
> Work top to bottom. Where a step says *why*, that's the specific bug the step
> is hunting. Report failures with the step number.

---

## A. Cold launch (2 min)

- [ ] **A1** App launches; icon on the home screen is the winged shoe, **no dark
      wedges in the corners** and no wordmark.
      *Why: the icon was rebuilt full-bleed from a pre-rounded mockup.*
- [ ] **A2** Today tab: ring renders, step count is non-zero after a short walk.
- [ ] **A3** Settings → version reads **0.25**.
- [ ] **A4** Grant Motion, then Location (When-In-Use), then Health when prompted.
      Each prompt should have plain-language copy.

---

## B. Workout library  *(new in v0.24, never run)*

- [ ] **B1** Activity tab → **Browse workouts** opens the sheet.
- [ ] **B2** All five category chips switch content: Start out / Speed /
      Endurance / Hills / Recovery.
- [ ] **B3** Pick **Easy 5K** → sheet closes, type becomes **Distance**, field
      shows **5** (km) or **3.1** (mi) matching your unit setting.
      *Why: distance recipes are authored in meters and converted at display time.*
- [ ] **B4** Pick **Sprints** → type becomes **Intervals**, fields read 30 / 90 / 8.
- [ ] **B5** The button now shows the recipe name (e.g. "Sprints") instead of
      "Browse workouts".
- [ ] **B6** Now change the **Run type** picker by hand → the recipe name clears.
      *Why: an explicit Binding does this; `.onChange` would have wiped the name
      at the wrong moment. This step verifies the right one fires.*
- [ ] **B7** Switch units in Settings, reopen the library → **Easy 5K** summary
      re-renders in the new unit.

---

## C. Intervals  *(the riskiest untested logic)*

Set **Work 20s / Rest 15s / Reps 3** so a full cycle takes ~2 minutes.

- [ ] **C1** Start → 3-second countdown, then the timer runs.
- [ ] **C2** Banner shows **WORK**, "Rep 1 of 3", and a counting-down seconds value.
- [ ] **C3** At 20s it flips to **REST** and the voice says a rest cue.
- [ ] **C4** Rep counter increments correctly — **it should reach exactly 3, not 2 or 4.**
      *Why: off-by-one in the work/rest state machine is the classic bug here.*
- [ ] **C5** On the final work interval the voice says the **"last one"** cue.
- [ ] **C6** After the last rep the voice says **intervals complete**, and the
      banner stops advancing.
- [ ] **C7** Let it run ~30s past completion — it must **not** loop back to rep 1.
- [ ] **C8** Finish → session saves.

---

## D. Pace  *(shipped v0.15, never run)*

Set a target you can deliberately miss in both directions — e.g. **8:00 /km**.

- [ ] **D1** Type `8:00` → starts without complaint.
      *Why: `parsePace` handles "mm:ss"; a bad parse silently yields no target.*
- [ ] **D2** Banner shows **Target**, **You**, and a verdict line.
- [ ] **D3** Walk slowly → verdict goes **"Pick it up"** (red) and after ~25s the
      voice nudges.
- [ ] **D4** Run fast → verdict goes **"Ease off"** (gold).
- [ ] **D5** Hold steady → **"On pace"** (green).
- [ ] **D6** Stand completely still → **no voice nudge** (guarded below 0.4 m/s).
      *Why: without that guard it nags every 25s at a red light.*
- [ ] **D7** Nudges are **at most one per 25s**, not every tick.

---

## E. Live Activity / Dynamic Island  *(new v0.16, never run)*

- [ ] **E1** Start any session → swipe to home. Live Activity appears on the
      lock screen with label, time, distance.
- [ ] **E2** Dynamic Island **compact**: timer left, distance right.
- [ ] **E3** Long-press → **expanded** view renders without clipping.
- [ ] **E4** The timer **keeps ticking on its own** while the app is backgrounded.
      *Why: it uses `Text(timerInterval:)` — it should advance with the app suspended.*
- [ ] **E5** Distance updates roughly every 10s (not frozen, not every second).
- [ ] **E6** During an **intervals** session the detail line shows WORK/REST.
- [ ] **E7** Finish the session → the Live Activity **disappears**.
      *Why: a stranded Live Activity that never ends is a visible, annoying bug.*
- [ ] **E8** Force-quit the app mid-session → confirm no zombie Live Activity persists.

---

## F. GPS + route

- [ ] **F1** Outdoor run with GPS on → live map draws a polyline.
- [ ] **F2** Collapse/expand the map card.
- [ ] **F3** Walk under cover / through a tunnel → distance still advances and
      any bridged gap is flagged **estimated**.
- [ ] **F4** Session detail → full route map + splits render.

---

## G. Voice

- [ ] **G1** Cues duck music rather than stopping it.
- [ ] **G2** Cues play through **AirPods**.
- [ ] **G3** Distance milestone cue fires at 1 km / 1 mi.
- [ ] **G4** Voice is the **deadpan** pack ("Good for you." / "Neat.").
- [ ] **G5** Settings → Voice coaching **off** → silence for a whole session.

---

## H. Health + persistence

- [ ] **H1** Finish a run → it appears in **Apple Health** as a workout.
- [ ] **H2** The workout carries a **route** (map in Health).
- [ ] **H3** Active energy is written.
- [ ] **H4** History lists the session with the right type/distance/duration.
- [ ] **H5** Force-quit and relaunch → history survives.
- [ ] **H6** Edit distance / add a note → persists.
- [ ] **H7** **Do Again** re-creates the setup.

---

## J. Pause / resume  *(new v0.27)*

- [ ] **J1** Start a session → **Pause** appears beside Finish.
- [ ] **J2** Tap Pause → timer stops, greys out, "PAUSED" shows.
- [ ] **J3** Wait 30s → the timer has **not** advanced.
- [ ] **J4** Walk 20 m while paused, then Resume → **distance did not increase**
      for that stretch, and the route has no straight line across it.
      *Why: resume drops `lastLocation` precisely so the paused stretch is
      neither counted nor bridged.*
- [ ] **J5** After resume the timer continues **from where it stopped**, not
      from wall-clock start.
- [ ] **J6** Pause/resume 3× → time stays consistent, no drift or jumps.
- [ ] **J7** Pause during an **intervals** session → the rep countdown freezes
      and resumes mid-rep, not restarting the rep.
- [ ] **J8** While paused the Live Activity detail reads **"Paused"**.
- [ ] **J9** Pause, then **Finish while still paused** → saved duration excludes
      the paused time and looks right.
- [ ] **J10** Paused with GPS on → no drift-distance accumulates while stationary.

---

## K. Export  *(new v0.27)*

- [ ] **K1** Settings → Data → **Export My Data** is *disabled* with no sessions.
- [ ] **K2** With sessions recorded, it enables; tapping opens the share sheet.
- [ ] **K3** The set contains one **CSV** plus one **GPX per session with a route**.
- [ ] **K4** Save to Files → open the CSV → header row plus one row per session,
      values aligned to the right columns.
- [ ] **K5** A session with a note containing a **comma** stays in one field.
      *Why: RFC 4180 quoting — an unquoted comma would shift every later column.*
- [ ] **K6** Email/AirDrop a GPX to yourself and import it somewhere that reads
      GPX (Strava, Garmin, Gaia) → **the route renders correctly.**
      *Why: this is the whole portability claim. If it doesn't import, it's broken.*
- [ ] **K7** Export with ~20+ sessions → completes without a visible freeze.

---

## L. Streaks  *(new v0.27)*

- [ ] **L1** Today tab shows the streak card.
- [ ] **L2** With no history: "No streak yet" and "0 of 3 active days this week".
- [ ] **L3** Record sessions on 3 separate days → card flips to
      "This week's done — rest is training too."
- [ ] **L4** Settings → **Active days a week** stepper (1–7) changes the target,
      and the card updates.
- [ ] **L5** Take a rest day → the streak **does not** reset.
      *Why: this is the entire point — weekly, not daily.*
- [ ] **L6** Nothing anywhere nags you to protect a streak.

---

## M. Known gaps (do NOT file these)

Still open, scheduled in `ROADMAP.md`:

- First-run/empty states and permission-denied copy are unpolished. *(1.4)*
- No widgets, Siri, or personality packs yet. *(Phase 2)*

---

## Reporting

For each failure note: **step number**, what happened, and whether it reproduces.

**Highest-value steps** — logic that can only fail at runtime, each mapping to a
specific suspected defect: **C4, C7** (interval off-by-one / looping),
**D6** (pace nagging at red lights), **E4, E7** (Live Activity ticking /
stranded), **J4, J9** (pause distance + duration accounting), **K5, K6**
(CSV quoting, GPX actually importing).
