# RunKit — Analytics research & design

> What's worth measuring for a runner, what RunKit can compute **today**, what
> needs heart rate, and how the Stats page is laid out.
> Companion to `V2_DESIGN.md` (readiness/recovery) and `ROADMAP.md`.

---

## 1. The key finding: heart-rate analytics don't need a Watch *app*

The obvious assumption is "HR analytics ⇒ build the Watch app first." That's wrong,
and it changes the build order.

**HealthKit already exposes heart rate written by any source** — Apple Watch, a
chest strap, another app. If the user wears a Watch on a run, RunKit can query
`heartRate` samples for the session's time window and compute average, max,
zones and drift **with no Watch target at all**. It's a read permission, not a
new app.

Several derived metrics come free the same way — Apple Watch computes them and
files them in HealthKit:

| Type | Identifier | Notes |
|---|---|---|
| Heart rate | `heartRate` | Sampled continuously during a Watch workout |
| Resting HR | `restingHeartRate` | Daily; the classic fitness trend line |
| HRV | `heartRateVariabilitySDNN` | Feeds readiness (`V2_DESIGN.md` §4) |
| VO₂ max | `vo2Max` | **Apple computes this** — a free fitness score |
| Recovery HR | `heartRateRecoveryOneMinute` | Drop 1 min post-workout; strong fitness signal |

**Implication:** ship HR analytics as a *read* feature now, gated on "we found
samples". Watch owners get the full page immediately. The Watch app remains
worth building — for phone-free runs and live in-run HR — but it is **not a
prerequisite for analytics.** That reorders Phase 3.

---

## 2. What matters to runners (and what RunKit can compute)

### Tier 1 — available today, no HR
| Metric | Why it matters | Source |
|---|---|---|
| **Volume** (distance / time / count per week, month, year) | The base of every training decision | `ActivitySession` |
| **Consistency** (active days, weekly streak) | Better predictor of progress than any single run | already shipped |
| **Pace trend** | Is the same effort getting faster? | `activeSeconds ÷ distanceMeters` |
| **Personal records** (fastest 1 K / 1 mi / 5 K / 10 K, longest, best pace) | The most-checked screen in any run app | splits from `RoutePoint` |
| **Elevation gain** | Contextualises a "slow" run | `RouteMath.elevationGain` |
| **Cadence** (steps/min) | Form metric; ~170–180 is the usual target. **No Watch needed** — `CMPedometer` already gives steps | `ActivitySession.steps ÷ activeSeconds` |
| **Training load / ACWR** | 7-day load ÷ 28-day load. **>1.5 is an established elevated-injury-risk band** — a genuinely useful, honest warning | derived |

### Tier 2 — needs heart rate (read from HealthKit)
| Metric | Why it matters |
|---|---|
| **Avg / max HR per session** | Table stakes |
| **Time in zones** | 5 zones from max HR, or Karvonen using resting HR (more accurate) |
| **Training distribution (80/20)** | Polarized training: ~80% easy, ~20% hard. Most amateurs run their easy runs too hard — showing this is genuinely actionable |
| **Aerobic decoupling** | Pace:HR ratio, first half vs second half. **>5% drift suggests an underdeveloped aerobic base.** Strong differentiator — few consumer apps surface it |
| **Efficiency factor** | Speed ÷ avg HR. Trends upward as fitness improves; controls for weather/terrain better than raw pace |
| **VO₂ max trend** | Read straight from HealthKit |
| **Resting HR trend** | Downward = adaptation; a spike = fatigue or illness |

### Deliberately excluded
Anything requiring a server, a social graph, or a proprietary score. No "RunKit
Score™" black box — every number shown must be explainable in one line. That is
the same discipline as the honest-estimates principle, applied to analytics.

---

## 3. Zone model

Default to **Karvonen (heart-rate reserve)** when resting HR is available, since
it's meaningfully more accurate than plain %max:

```
HRR      = maxHR − restingHR
zoneLow  = restingHR + HRR × pct
```

| Zone | % HRR | Purpose |
|---|---|---|
| 1 Recovery | 50–60 | Active recovery |
| 2 Easy | 60–70 | Aerobic base — where most volume belongs |
| 3 Steady | 70–80 | "Grey zone" — easy to overuse |
| 4 Threshold | 80–90 | Lactate threshold |
| 5 VO₂ | 90–100 | Intervals |

`maxHR`: prefer an observed max from HealthKit history over `220 − age`, which is
notoriously inaccurate (±10–12 bpm). Let the user override. Age comes from
`SuiteProfile`, already shared across the suite.

---

## 4. Page design — "Stats"

Replaces the History tab. History becomes one segment of it rather than its own
destination, since a bare session list is the least valuable thing on the tab.

```
Stats                                   [ Summary | Records | Sessions ]

SUMMARY        period: [Week] [Month] [Year] [All]
  ┌ Distance ─┬ Time ─────┐
  │ 42.3 km   │ 4h 12m    │      hero tiles
  ├ Sessions ─┼ Elevation ┤
  │ 6         │ 340 m     │
  └───────────┴───────────┘
  Weekly distance          ▁▃▅▂▇▄█   bar chart
  Average pace             ╲╱╲___    line chart
  Training load            1.2 · balanced
  Heart rate               (empty state until samples exist)

RECORDS
  Fastest 1 K / 1 mi / 5 K / 10 K
  Longest distance · Longest duration · Best average pace
  Biggest week · Biggest month

SESSIONS
  the existing list, with delete + detail navigation
```

### Naming
**"Stats"**, not "Progress" — and not for style reasons: SwiftUI already defines
`ProgressView`, so a `struct ProgressView: View` in this module would shadow it
and break every existing use (`SettingsView` uses one in the export button).
`StatsView` avoids the collision outright. "Insights"/"Trends" were the other
candidates; "Stats" is plainer and matches what the tab actually shows.

### Empty states
Analytics on two sessions is noise. Each section states its own threshold rather
than rendering a misleading chart:
- Trends need **≥3 sessions**
- Training load needs **≥14 days** of history
- HR sections need **≥1 session with samples**

---

## 4b. Aerobic decoupling — research

### What it is
Over a steady aerobic effort, compare **output ÷ heart rate** in the first half
against the second. If heart rate creeps up while pace holds — or pace fades
while heart rate holds — the two have *decoupled*. Popularised by Joe Friel and
TrainingPeaks (as **Pa:Hr** for pace, **Pw:Hr** for cycling power).

```
EF₁ = avg speed (first half)  ÷ avg HR (first half)
EF₂ = avg speed (second half) ÷ avg HR (second half)
decoupling % = (EF₁ − EF₂) ÷ EF₁ × 100
```

The conventional reading: **under ~5% means your aerobic base supports that
duration at that intensity**; above it means it doesn't — yet. Treat 5% as a
widely-used coaching heuristic, not a clinical threshold.

### Why it's worth tracking — the case
1. **It controls for conditions in a way raw pace cannot.** Pace is confounded by
   heat, wind, hills, sleep and fatigue, so "am I getting fitter?" is genuinely
   hard to answer from pace alone. Decoupling is a *within-run* ratio, so it
   cancels much of that: it asks whether you held together, not how fast you were.
2. **It validates the easy running RunKit already nudges toward.** The 80/20 card
   tells you *how much* easy running you did; decoupling tells you whether that
   easy running is **working**. Falling decoupling on comparable runs is direct
   evidence the aerobic base is improving. Those two cards answer a complete
   question together, which is a stronger product story than either alone.
3. **It's an early fatigue/illness signal.** A familiar route at a familiar effort
   that suddenly decouples 10% instead of 4% points at heat stress, dehydration,
   under-fuelling or oncoming illness — often before it's consciously noticed.
   That feeds the v2 readiness score (`V2_DESIGN.md` §4) with a signal derived
   from RunKit's own data rather than another HealthKit read.
4. **It's a genuine differentiator.** Decoupling lives in the "serious" tools —
   TrainingPeaks, WKO, Golden Cheetah — and is largely absent from Strava, Nike
   Run Club and Apple Fitness. Shipping it free, on-device, fits the thesis of
   giving away what others gate.

### The honest caveats (these decide the design)
Decoupling is **only meaningful on the right kind of run**, and publishing it for
the wrong ones would be worse than not shipping it:

- **Steady aerobic efforts only.** Intervals, fartlek, hill repeats and races
  decouple by construction — the number is noise there.
- **Long enough to drift.** Below ~30 minutes there isn't enough run for the
  signal; 45+ minutes is the classic window.
- **Terrain sensitive.** Pace-based decoupling punishes a route that climbs in
  its second half. Cycling solves this with power; running power isn't standard
  enough to rely on. Mitigate by preferring flat routes and reporting elevation
  alongside.
- **Heat and humidity cause cardiac drift on their own** — via plasma-volume loss,
  not fitness. A hot-day reading isn't comparable to a cool-day one.
- **Fuelling matters** on long runs; glycogen depletion drifts HR upward.
- **Warm-up must be excluded**, or the first half is unfairly slow-and-low.
- **Starting too hard** skews the first half and flatters the result.

**Design consequence:** compute it only for sessions that qualify (steady,
≥30 min, GPS route present, not intervals/custom), exclude the first ~10 minutes,
and label it an estimate with the conditions caveat attached. Showing "—" with a
reason is better than showing a confident wrong number — the same honest-estimates
discipline as the calorie figures.

### What RunKit needs to build it
Everything required is already on the device:

| Input | Source | Status |
|---|---|---|
| HR time series | HealthKit `heartRate` for the session window | ✅ already queried (v0.41) |
| Pace time series | `RoutePoint` timestamps + coordinates | ✅ already recorded |
| Split point | session midpoint after warm-up trim | derived |

No new permission, no new sensor, **no Watch app**. The only real decision is
storage: keeping a per-session HR series would cost space, but decoupling can be
recomputed from HealthKit + `RoutePoint` on demand, so only the **result** needs
persisting — one `Double` plus a validity reason, alongside the existing HR
summary fields.

### Companion metric: Efficiency Factor
Same ratio, tracked *across* sessions instead of within one:
`EF = avg speed ÷ avg HR`. Rising EF over weeks on comparable easy runs is the
cleanest single "aerobic fitness is improving" line RunKit could plot — and it's
computable **right now** from the avg HR already cached in v0.41, with no series
data at all. Cheaper than decoupling and worth doing first.

---

## 5. Build order

| # | Item | Effort | Notes |
|---|---|---|---|
| 1 | `StatsCalculator` + Summary/Records/Sessions frame | M | Tier 1 only — ✅ **v0.40** |
| 2 | Swift Charts: weekly volume, pace trend | M | iOS 17 target, no dependency |
| 3 | Read `heartRate` + derived types from HealthKit | M | ✅ **v0.41** — Tier 2 unlocked with no Watch app |
| 4 | Zones + 80/20 distribution | L | ✅ **v0.41** |
| 4a | **Efficiency Factor** (metres per heartbeat, trended) | S | ✅ **v0.43** |
| 4b | **Aerobic decoupling** (see §4b) | M | ✅ **v0.43** — computed from the HR samples already fetched plus `RoutePoint`; only the result is persisted, gated on qualifying runs with a stated reason otherwise |
| 5 | Persist HR summary on `ActivitySession` | S | ✅ **v0.41** — avg/max/zone seconds cached at save, with a bounded backfill for older sessions |
| 6 | Watch app | XL | For *live* HR + phone-free runs — no longer blocks analytics |

**Reordering note:** `ROADMAP.md` Phase 3 put the Watch app (3.6) ahead of HR
analytics. Item 3 above shows that's unnecessary — HR analytics can ship in
Phase 2 as a read-only feature, and the Watch becomes a separate, later win.
