# RunKit — Execution Roadmap

> The authoritative **work plan**. Companions: `REQUIREMENTS.md` (what the app is),
> `DIFFERENTIATION.md` (why these features), `V2_DESIGN.md` (how the v2 tentpoles work).
> Last updated at **v0.27**.

Effort scale: **S** ≤ half a session · **M** 1–2 · **L** 3–5 · **XL** 6+.
Risk reflects *build-blind risk* — no Xcode on the dev machine, so everything is
verified on Codemagic/device, and new frameworks cost more than new logic.

---

## 0. Current state (honest)

**Built and pushed (v0.24):** Today ring + stat tiles · Walk/Run/Ride sessions ·
opt-in GPS with route map, splits, elevation · GPS-gap fallback distance with
"estimated" flagging · session detail/edit/delete/Do-Again · HealthKit workout +
route + energy write · 5 workout types (free/distance/time/intervals/**pace**)
with per-mode voice coaching · deadpan clip-pack voice (140 clips) · Live
Activity / Dynamic Island · 16-workout library · new app icon · signed
TestFlight workflow wired to LiftKit's shared credentials.

**✅ Compile debt cleared.** v0.15–v0.25 were written blind, but the signed
build succeeded and **shipped to TestFlight** — so everything compiles, the
widget extension's second bundle ID signs correctly, and App Store Connect
validation passes. The signing path (LiftKit's shared credentials + the two
App IDs) is proven end-to-end.

**⚠️ Still unverified: runtime behaviour.** Compiling is not working. The
blind-built features have never been *exercised* — intervals state machine,
pace nudges, Live Activity, workout library, voice cues in each mode. Phase 0
is now a **device smoke test**, not a build fix.

**⚠️ Spec gaps found in audit** — three items are in the v1 scope document but
are *not implemented*. They're folded into Phase 1 below:
| Gap | Spec ref | Status |
|---|---|---|
| Export (CSV/GPX) | §4.4 "Data management" | ✅ **Built v0.27** |
| Streaks | §3 table-stakes | ✅ **Built v0.27** — weekly, rest-day aware |
| Pause / resume a session | *not specced* | ✅ **Built v0.27** |

---

## Phase 0 — Verify and stabilize  *(blocks everything)*

| # | Item | Effort | Status |
|---|---|---|---|
| 0.1 | Signed build compiles, signs, validates | S | ✅ **Done** — on TestFlight |
| 0.2 | **Device smoke test** — see `TESTFLIGHT_CHECKLIST.md` | M | ⬅️ **Here** |
| 0.3 | Fix behavioural bugs found on device | M | Blocked on 0.2 |

**Acceptance:** an interval session run end-to-end, Live Activity visible in the
Dynamic Island, a library workout picked and completed, and the session landing
in Apple Health with its route.

> Do 0.2 **before** writing another feature. The failure mode now isn't compile
> errors — it's a state-machine bug that only shows up at rep 7 of a real run.

---

## Phase 1 — v1.0 (App Store launch)

### 1a. Close the spec gaps
| # | Item | Effort | Risk | Why now |
|---|---|---|---|---|
| 1.1 | **Pause / resume** a session | M | Low | ✅ **v0.27** — `elapsed` subtracts paused time so intervals/goals/pace freeze for free; GPS suspends without resetting distance |
| 1.2 | **Export CSV + GPX** | M | Low | ✅ **v0.27** — CSV session log + GPX 1.1 per route, via share sheet |
| 1.3 | **Streaks** (rest-day aware) | S–M | Low | ✅ **v0.27** — weekly not daily; configurable target; no pressure copy |
| 1.4 | Empty/first-run states, permission-denied copy | S | Low | ⬅️ **Remaining** — review-visible polish |

### 1b. Ship it
| # | Item | Effort | Blocker |
|---|---|---|---|
| 1.5 | Register App IDs `com.ferrixguild.runkit` + `.widgets`; enable **HealthKit** | S | **You** — developer.apple.com |
| 1.6 | App Store Connect record; reserve *RunKit: No-Login Run Tracker* | S | **You** |
| 1.7 | Confirm `signing` group visible to RunKit (reuse LiftKit's key) | S | **You** — Codemagic |
| 1.8 | Run signed workflow → TestFlight | S | 1.5–1.7 |
| 1.9 | Screenshots (6.7" + 6.1"), subtitle, description, keywords | M | — |
| 1.10 | Privacy questionnaire — location **used, not linked, not tracking** | S | — |
| 1.11 | Internal TestFlight soak, then submit | — | — |

**Acceptance:** approved on the App Store with the "Data Not Collected" label intact.

---

## Phase 2 — v1.1 (fast-follow)

Ordered by **value ÷ effort**. All independent — ship in any order, or drop any.

| # | Item | Effort | Risk | Notes |
|---|---|---|---|---|
| 2.1 | **Widgets** (home + lock) | M | Med | `RunKitWidgets` target already exists from the Live Activity — this is incremental, not new infrastructure. Today's steps/distance + last session |
| 2.2 | **App Intents / Siri / Shortcuts** | M | Med | "Hey Siri, start a RunKit run", Action-button, Automations ("when I arrive at the park"). Power-user hook Strava lacks; new framework = real risk |
| 2.3 | **Pace from my recent average** | S | Low | One tap fills the pace field from your own last runs. Closes the "you must already know your target" gap **honestly** — real data, not a guessed number. Down-payment on 3.3 |
| 2.4 | **Coach personality packs** (Hype / Zen / Drill Sergeant) | M | Low | Cheapest big win — reuses the whole cue pipeline; only the phrase table + clip pack change. Best App Store screenshot. **Caveat:** each pack needs a Kokoro clip render, or it falls back to system TTS and sounds inconsistent |
| 2.5 | **Honest streaks** | S | Low | Streaks that respect rest days; no nagging, no shaming. Anti-pattern positioning vs. Nike/Strava (merge with 1.3 if that slipped) |
| 2.6 | **Map privacy zones** | M | Low | Auto-blur route start/end near a saved home. Strava bolted this on after the 2018 heatmap scandal; RunKit does it natively. Strong privacy story |
| 2.7 | StandBy + Control Center widget | S | Low | Falls out of 2.1 |

**Recommended cut if time is short:** 2.1, 2.3, 2.4 — visible, low-risk, and 2.4
is the marketing asset.

---

## Phase 3 — v2.0 (differentiation tentpoles)

Design detail in `V2_DESIGN.md`. **Strictly ordered — each depends on the last.**

| # | Item | Effort | Risk | Depends on |
|---|---|---|---|---|
| 3.1 | **Planning calendar** + `PlannedWorkout` model | L | Med | — |
| 3.2 | Plan → session deep-link + completion matching | M | Med | 3.1 |
| 3.3 | **Training-plan generator** (goal + race date → weeks) | L | Med | 3.1, 3.2, and 2.3's pace math |
| 3.4 | **Readiness score** (HRV / RHR / sleep / load) | M | Med | New HealthKit read types |
| 3.5 | **Recovery-aware scheduling** ← *the moat* | L | **High** | 3.1–3.4 + LiftKit data to test against |
| 3.6 | **Apple Watch app** (on-wrist GPS + HR) | XL | **High** | New target + 3rd App ID/profile |
| 3.7 | Premium tier (StoreKit, anonymous) | L | Med | Stable v1 |

**Sequencing note:** 3.1–3.3 is the coherent "planning release" and could ship as
**v1.5** without 3.4–3.5. The Watch (3.6) is independent of everything else — it
can run in parallel or slip without blocking the moat.

**Hard gate before 3.5:** it needs real LiftKit workouts in HealthKit to test
against. Don't start it until you're actively using both apps on one device.

---

## Phase 4 — Suite / beyond

| # | Item | Effort | Notes |
|---|---|---|---|
| 4.1 | Extract **`KitUI`** shared package | L | Three copies of `Theme.swift` is the trigger; do it when FuelKit starts |
| 4.2 | FuelKit ↔ RunKit energy loop | M | Burn out, targets in — via HealthKit only |
| 4.3 | Activate dormant **iCloud sync** | M | Schema is already CloudKit-compatible; opt-in, user's own iCloud |
| 4.4 | Localisation | L | Only if traction justifies it |

---

## Cross-cutting risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Build-blind development** | Compounding — Phase 0 exists because of it | Build after every 1–2 features, never 5 |
| **Widget/Watch signing** | Blocks release | Each new target = a new App ID + profile; the signed workflow already handles two — add the third *with* the Watch |
| **SwiftData migration** | Data loss for TestFlight users | New `@Model` types are additive/safe; changing existing fields is not. Test upgrades once real users have data |
| **Scope creep toward Strava** | Kills the thesis | `DIFFERENTIATION.md` §4 guardrails — no feed, no accounts, ever |
| **Voice pack maintenance** | Blocks 2.4 | Each personality = a Kokoro render pass; budget it or accept TTS fallback |

---

## Open decisions

1. **Calendar placement** — own tab (5 total) or a segment in History? *Leaning own tab.*
2. **v1.5 split** — ship 3.1–3.3 as a planning release before readiness/recovery? *Leaning yes; it de-risks the moat.*
3. **Premium boundary** — free forever vs. Plus (`V2_DESIGN.md` §6). Non-negotiable: **export stays free**.
4. **Watch voice** — ship the clip pack twice (bundle size) or system TTS on wrist? *Leaning TTS.*
5. **Personality packs free or paid?** They're the best marketing asset — leaning at least one free extra.

---

## Immediate next three actions

1. **Trigger the unsigned Codemagic build on `master`** → send me the log. *(0.1)*
2. While it runs: **register the two App IDs + HealthKit capability.** *(1.5)*
3. On a green build: **AltStore install and smoke-test** the blind-built features. *(0.3)*
