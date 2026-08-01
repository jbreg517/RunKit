# Suite Health Sync — the definitive spec

How LiftKit, RunKit and FuelKit share health data, and what the user is told.
Companion to `SUITE-STORE-FIX.md`. This file is the shared contract and lives in
all three repos (`LiftKit/docs`, `RunKit/docs`, `FuelKit/docs`) — keep the copies
in sync.

## Implementation status (2026-07-31)

**Done:**
- **Read-through profile reconciler** — `SuiteProfileSync` in LiftKit
  (`Models/HealthProfile.swift`) and FuelKit (`Services/SuiteProfile.swift`).
  Replaces the seed-once copy: on foreground each app pulls the shared profile when
  its `updatedAt` is newer (newest-wins), marking its own writes so it never
  re-applies them. RunKit already reads the shared profile live, so it needs no
  reconciler. Fixes the "logged in one app, never showed in the others" symptom for
  goals + measurements.
- **LiftKit `SuiteProfile` decoder aligned** — now has the same forgiving
  `decodeIfPresent` `init(from:)` as FuelKit/RunKit, so future field additions can't
  make LiftKit silently drop the shared profile.
- **FuelKit reads active energy** — `HealthKitManager.activeEnergyBurned(on:)` sums
  the day's `activeEnergyBurned` and the calorie budget shows *base goal + exercise*
  (macros stay on the base goal). This is the HealthKit-authorised path of the
  precedence rule and fixes "LiftKit's workout burn never appears in FuelKit"
  whenever Health is on. **Existing FuelKit users who already granted Health must
  re-trigger authorisation** (toggle off/on) to grant the new read type.
- **FuelKit writes dietary energy + macros** (2026-08-01) —
  `HealthKitManager.saveNutrition(...)` publishes each day's calories + protein/
  carb/fat to HealthKit (source-scoped delete-and-rewrite so totals never
  double-count), hooked into `NutritionLog` after every add/edit/delete and mirrored
  for the viewed day. This is what lets LiftKit (which already reads dietary energy +
  macros) finally see FuelKit's food. Same re-authorisation caveat — the dietary
  *write* types are new.

**Deferred (next step):**
- **App-Group `activeKcal` fallback** for the Health-*off* path (precedence rule
  step 2). Requires adding the `SuiteActivity` channel + a publisher to **LiftKit**,
  which today has no such channel — a new file in LiftKit's real `.pbxproj` (not
  XcodeGen), so it needs pbxproj surgery and can't be compile-checked locally.
  Until then, the LiftKit→FuelKit burn path works only with Health authorised.
- **Darwin-notification change signal** (§4) — apps currently reconcile on
  foreground, not the instant another app writes.

This is a design spec; the sections below are the target design regardless of what
is wired yet.

## 1. Two channels, two jobs

There is no shared database (three apps writing one store is what destroyed
FuelKit's food log twice — see `FuelKitApp.storeURL`). Sharing rides two
channels with a strict division of labour:

| | **App Group** (`group.com.ferrixguild.suite`) | **HealthKit** |
|---|---|---|
| Scope | Our 3 apps only | Every Health app + Apple Watch + Fitness |
| Reach | One device | Syncs across the user's devices via iCloud |
| Permission | None — always works | Opt-in, **off by default**, per-app |
| Survives app deletion | No | Yes |
| Holds goals / plans / load | Yes | No — not HealthKit concepts |
| Reads a Strava run / scale weight | No | Yes |

- **HealthKit = the boundary.** Ingest data that already existed before our app,
  interoperate with the Watch and third-party apps, sync across devices, survive
  reinstall. Source of truth for anything **measured**.
- **App Group = the interior.** Suite-only concepts HealthKit can't express, plus
  a permission-free fallback mirror of measurements so the suite works with Health
  switched off.

Neither replaces the other. Dropping HealthKit breaks first-run prefill, Watch
calorie accuracy, and all third-party interop. Dropping the App Group breaks
goals/plans/load and leaves nothing working when Health is off.

## 2. The precedence rule (authoritative)

For any **measured quantity** — bodyweight, height, active energy burned, dietary
energy:

1. **If HealthKit is authorised, HealthKit wins.** Read the most recent HK sample
   / the day's HK sum. HealthKit already aggregates the Watch + every app + our
   own writes, so it is the superset.
2. **Otherwise, use the App Group mirror** (`SuiteProfile.latestWeightLb`,
   `SuiteProfile.heightInches`, the `SuiteActivity` energy rollup).
3. **Never combine the two for the same quantity.** Reading HK *and* adding the
   App Group value double-counts (this is the Apple Watch calorie trap).
4. **On produce, write both.** When the user logs a weight or finishes a workout,
   write to HealthKit (if authorised) *and* update the App Group mirror. HK for
   the outside world; App Group for the permission-free suite path.

For **suite-only concepts** — goal type, goal weight, weekly rate, activity level,
protein/fat targets, training load, planned sessions:

5. **App Group only, always.** HealthKit has no representation for these.

For **profile fields** shared through the App Group (height, age, sex, goals),
resolve conflicts by **newest-wins on `SuiteProfile.updatedAt`**. Reconcile on
every foreground (see §4), not once at first launch.

### Worked example — FuelKit's calorie budget

`budget = intake − burn`. The **burn** term follows the rule exactly:

- HK authorised → `burn = HK activeEnergyBurned sum for the day`. This already
  contains LiftKit's and RunKit's workouts *and* the Watch. **Do not also add the
  App Group energy.**
- HK off → `burn = Σ activeKcal across the other apps' SuiteActivity feeds`.

## 3. First-run / onboarding order

A brand-new user of the *first* suite app they install has an **empty App Group**
— the only place their weight/height/DOB/sex can already exist is HealthKit. So
prefill in this order and stop at the first hit:

1. **HealthKit** (if the user grants it) — the only source that can carry data
   from before our app existed, from the Watch, or from another app.
2. **App Group `SuiteProfile`** — populated once a *second* suite app is installed.
3. **Ask the user.**

HealthKit is the fallback for the first app; the App Group is the fallback for the
second app onward. Today onboarding does neither reliably — Health is off by
default and not requested at onboarding, and the seed only reads the App Group.

## 4. Reconciliation mechanics

- **Read-through, not seed-once.** Replace every `if profiles.isEmpty { seed }`
  with a foreground reconcile: if `SuiteProfile.updatedAt` is newer than the local
  profile's last sync, pull shared → local. This is the fix for "logged in one
  app, never showed in the others."
- **Change signal.** App Group `UserDefaults` writes don't notify other processes.
  Use a Darwin notification (`CFNotificationCenterGetDarwinNotifyCenter`) posted on
  write so a backgrounded app refreshes without a force-quit.
- **Opportunistic HK → mirror.** Whichever app is foregrounded and has Health on
  copies the latest HK bodyweight into `latestWeightLb` (guarded by a small delta
  so it doesn't churn). FuelKit already does this in `NutritionView.task`.

## 5. Field matrix — what each app reads & writes (audited 2026-08-01)

**R** = reads, **W** = writes, **—** = not touched. Verified against each app's
HealthKit `readTypes` / `shareTypes` and the App Group stores.

### HealthKit

| Type | LiftKit | FuelKit | RunKit |
|---|---|---|---|
| `HKWorkout` (+ activity type) | R/W | — | W |
| `HKWorkoutRoute` (GPS) | — | — | W |
| `activeEnergyBurned` | R/W | R | R/W |
| `dietaryEnergyConsumed` | R | W | — |
| `dietaryProtein` / `dietaryCarbohydrates` / `dietaryFatTotal` | R | W | — |
| `bodyMass` | R/W | R/W | R |
| `height` | R/W | R/W | — |
| `distanceWalkingRunning` | R | — | W |
| `distanceCycling` | R | — | W |
| `stepCount` / `flightsClimbed` | — | — | R |
| `heartRate` / `restingHeartRate` / `heartRateVariabilitySDNN` / `vo2Max` / `heartRateRecoveryOneMinute` | — | — | R |
| `biologicalSex` / `dateOfBirth` (characteristics, read-only) | R | R | — |

LiftKit writes workouts + their burn and reads others' workouts/energy/distance for
a unified history. RunKit writes runs/rides (workout + route + energy + distance)
and reads the HR family (Watch-supplied). FuelKit writes food (energy + macros) and
reads energy for its calorie budget. Sex/DOB are user-set in the Health app and can
only be read.

### App Group — `SuiteProfile` (`SuiteProfileStore`, key `suiteHealthProfile`)

One shared JSON blob; every field forward/backward compatible (§7).

| Field | LiftKit | FuelKit | RunKit |
|---|---|---|---|
| heightInches | R/W | R/W | — |
| age | R/W | R/W | R |
| biologicalSex | R/W | R/W | — |
| latestWeightLb | R/W | R/W | R |
| goalType / goalWeightLb / weeklyRateLb | R/W | R/W | — |
| activityLevel | R/W | R/W | — |
| proteinPerLb / fatPercent | R/W | R/W | — |
| updatedAt | newest-wins reconcile marker (all apps) | | |

RunKit is a read-only consumer (weight for calorie math, age for HR zones); LiftKit
and FuelKit both edit the goal + measurements.

### App Group — `SuiteActivity` (`SuiteActivityStore`, keys `suiteActivityFeed.<app>`)

`SuiteDailyLoad` (date, kind, load 0–1, perceivedEffort, sessionCount) +
`SuitePlannedSession` (date, kind, title, plannedMinutes, plannedLoad).

| App | Role |
|---|---|
| RunKit | **W** — publishes daily load + planned runs |
| FuelKit | **R** — `SuiteTrainingCard` shows today's cross-app load + next planned session (informational only, never touches the calorie math) |
| LiftKit | **absent** — has no `SuiteActivity` file, so it neither publishes nor reads |

### Open gaps (this audit)

- **LiftKit is missing from `SuiteActivity` entirely.** It should publish its
  lifting load + planned workouts (a `SuiteActivityPublisher` like RunKit's) so the
  channel carries strength training, not just runs. This is the **enabler** for the
  next item.
- **RunKit doesn't consume `SuiteActivity`.** It should read
  `totalLoad(excluding: .runkit)` for recovery-aware guidance ("you lifted hard
  yesterday — take it easy"). Only meaningful once LiftKit publishes, since RunKit
  excludes its own feed and is currently the sole producer. FuelKit's consumer
  (`SuiteTrainingCard`) already reads the channel — so RunKit's runs surface in
  FuelKit today; LiftKit's lifts will once it publishes.
- **App-Group energy fallback (Health-off path) not built.** `activeEnergyBurned`
  only crosses via HealthKit; with Health off there's no `activeKcal` on the App
  Group, so FuelKit's burn reads 0 (precedence rule §2 step 2).
- **No Darwin change-signal** — the profile reconciles on foreground, not instantly.
- **`SuiteProfile` carries no shared *consumed* macros** — FuelKit's daily macro
  totals reach LiftKit only through HealthKit (dietary types), which needs Health
  authorised in both apps. There is deliberately no App-Group macro mirror.

## 6. What the user is told

### The truth about "overwriting" — HealthKit never does

HealthKit is **additive and source-attributed**. When our app writes a weight, it
stores a **new sample tagged with our app**; the scale's reading, the Watch's
reading, and every other app's readings all still exist, each tagged with its own
source. Our app can only **edit or delete samples it wrote itself** — the API
forbids touching another source's data. A "latest weight" query returns the most
recent *by date*, so a fresh log is shown because it's newer, not because anything
was replaced.

So the honest message is the reassuring one, and it maps cleanly onto the two
permission types:

- **Write (Update / "share to Health"):** "We add a reading; we never change or
  remove data written by your Watch or other apps."
- **Read (Share / "read from Health"):** "We only read; we never modify it."

The one place a value really is *replaced* is **inside our own suite**: newest-wins
means logging a weight in FuelKit updates the number LiftKit and RunKit display.
That is intended (one profile across the suite) and non-destructive — per-app
weight history and HealthKit samples are untouched. It deserves one plain sentence,
e.g. *"Updates your weight across your LiftKit, RunKit and FuelKit apps."*

### Per-type toggle screens — what we can and can't control

The **granular per-type toggles are Apple's system authorisation sheet**, and Apple
does not let us add custom text next to each row. What we control:

1. **The usage-description strings** (`NSHealthShareUsageDescription` /
   `NSHealthUpdateUsageDescription`) shown at the top of that sheet. Ours are in
   good shape today — they name what's read, what's written, why, and say "stays on
   your device."
2. **Our own pre-permission priming screen**, shown *before* we call
   `requestAuthorization`. This is where a per-type, plain-language explanation
   belongs if we want one — full layout control, and it lifts grant rates because
   the system sheet only gets one shot.
3. **The footer under our own master toggle** in Settings.

Because HealthKit is additive, the meaningful thing to communicate per type is not
"what we overwrite" (nothing) but the **read-vs-write split** — which is exactly
the Share/Update boundary. A priming screen can list, tersely:

> **We save to Health:** workouts, calorie burn, weight, height — added as new
> readings, never replacing your other apps'.
> **We read from Health:** weight, height, calories, workouts from your Watch and
> other apps — read-only.

### Current state vs. gaps

- ✅ Usage strings: accurate and scoped (see each app's `Info.plist`).
- ✅ Master-toggle footer explains suite sync (FuelKit: "…so your targets match
  LiftKit, RunKit… Your goal is shared privately across the suite.").
- ✅ Failure feedback: LiftKit flips the toggle back and explains if Health is
  unavailable or denied.
- ⚠️ No pre-permission priming screen — we jump straight to Apple's sheet.
- ⚠️ Nothing states the additive / "never overwrites others" reassurance.
- ⚠️ Nothing states the intra-suite newest-wins behaviour.

None of these gaps is a blocker; they're the difference between "compliant" and
"the user actually understands what's happening."

## 7. Locking in the schema

The App Group wire format is already forward/backward compatible by construction:
every field decodes as `decodeIfPresent(...) ?? default` (see the note on
`SuiteProfile.init(from:)`). An old app ignores unknown fields; a new app fills
defaults for absent ones. So the schema is never frozen — **you can commit the
push/pull code now and add fields anytime**, provided the discipline holds:

- one shared source file, **byte-identical** across all three apps;
- **append only** — never rename or remove a field;
- **every field has a default.**

The universal fields (weight, height, age, sex, active/dietary energy, goals) are
physiologically stable and Apple-defined — treat them as done and wire them fully.
Let the speculative fields (load normalisation, planned-session shape, macros
beyond protein/fat) evolve on the same tolerant format at zero cost.
