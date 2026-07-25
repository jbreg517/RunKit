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

## 5. Build order

| # | Item | Effort | Notes |
|---|---|---|---|
| 1 | `StatsCalculator` + Summary/Records/Sessions frame | M | Tier 1 only — ✅ **v0.40** |
| 2 | Swift Charts: weekly volume, pace trend | M | iOS 17 target, no dependency |
| 3 | Read `heartRate` + derived types from HealthKit | M | Unlocks Tier 2 **without** a Watch app |
| 4 | Zones, distribution, decoupling, efficiency factor | L | Needs 3 |
| 5 | Persist HR summary on `ActivitySession` | S | Avoids re-querying HealthKit per render |
| 6 | Watch app | XL | For *live* HR + phone-free runs — no longer blocks analytics |

**Reordering note:** `ROADMAP.md` Phase 3 put the Watch app (3.6) ahead of HR
analytics. Item 3 above shows that's unnecessary — HR analytics can ship in
Phase 2 as a read-only feature, and the Watch becomes a separate, later win.
