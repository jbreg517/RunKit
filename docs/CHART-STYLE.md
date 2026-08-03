# Suite chart style

One cadence and one look for every graph across LiftKit, RunKit and FuelKit, so a
weight trend reads the same whichever app drew it. LiftKit holds the reference
implementation (`LiftKit/Views/Progress/StatsView.swift`, the `LKChart` /
`LKChartBucket` / `LKAggPoint` types + the `.lkTimeAxis(days:)` modifier); RunKit
and FuelKit should port the same helpers rather than re-deriving the rules.

These decisions were made deliberately — don't quietly diverge. If a chart needs to
break a rule, say why in a comment.

## 1. Cadence — aggregate longer ranges

Short ranges stay per-entry; longer ranges aggregate into buckets so a line is a
readable trend, not a cloud of points.

| Range (days)   | Bucket      |
|----------------|-------------|
| ≤ 7 (1 week)   | per-entry   |
| 8 – 100        | weekly      |
| > 100 / "all"  | monthly     |

`LKChartBucket.forRange(days:)` encodes this. **1 week never aggregates** — weekly
buckets would collapse it to a single point.

### Reducers (how a bucket's samples collapse to one value)

Pick per metric, by what the chart is actually claiming:

- **Progress-style "best"** (heaviest lift, best reps) → `.max`
- **Totals** (tonnage, hard sets, distance, calories burned) → `.sum`
- **Levels** (bodyweight, resting HR, a measurement) → `.mean`, or use the trend
  line (§4) and keep raw points per entry
- **Latest state** → `.last`

## 2. Axis — ~4 consistent, centered labels

Never rely on Swift Charts' automatic date axis — it picks ragged, off-center
labels. Use `.lkTimeAxis(days:)`, which targets ~4 evenly spaced labels and
**centers month/week labels under their span**, with faint gridlines:

- ≤ 10 days → automatic (~4), `MMM d`
- ≤ 45 days → weekly stride, `MMM d`, centered
- ≤ 130 days → monthly stride, `MMM`, centered
- longer → automatic (~5), `MMM`

Pair it with `.chartXScale(domain: rangeStart...now)` so a range always fills its
window even when data is sparse.

## 3. Dots — a dot means "you logged that"

A point on a line marks a **real entry** (a weigh-in, a workout, a logged day), not
an interpolated tick. Rules:

- Same color as its line (categorical charts: the series color).
- Drawn **on top of** the line, ringed in the **background color** (a slightly
  larger background-colored `PointMark` underneath) so a dot sitting on the line
  stays visible. This was a real bug in LiftKit's weight chart — faint dots
  vanished on the trend line.
- No dot where there's no entry. Gaps are information.

## 4. Trend over noise (jittery metrics)

For a naturally noisy metric — bodyweight above all — lead with a smoothed trend
line and demote the raw readings to quiet (but visible, see §3) dots.

- Smoother: **`LKChart.recencyWeightedTrend`** — an irregular-interval EWMA
  (`halfLifeDays` ≈ 10). Tolerates sparse, uneven weigh-ins where a fixed N-day
  average barely smooths, and lags less than a trailing window.
- Surface the **measured rate** from the trend's slope
  (`LKChart.ratePerWeek`) as the headline number (e.g. "▼ 0.8 lb/wk") — that's
  the actionable value, not the raw scale reading.
- Raw dots stay grey in both themes, pronounced enough to read on the line.

## 5. Split-by-color charts — dim-to-focus legend

When lines are split by color (muscle, activity type, macro):

- Hide the built-in legend (`.chartLegend(.hidden)`).
- Define an **explicit** foreground-style scale from `LKChart.categorical` so a
  custom legend's chips match the lines exactly.
- Build a tappable legend of chips. Tapping one **isolates** its line — that line
  stays full-strength, the others drop to ~0.18 opacity; tapping again clears.
  (Isolate/dim, not hide — context stays visible.)
- Reset the focus when the chart's subject changes.

`LKChart.categorical` leads with the app's own semantic colors (accent, blue,
green, red) so a split chart still feels like the app.

## 6. Baseline bands (self-referential)

Whoop/Oura-style: shade a faint "your typical" band behind a bar/line so an
outlier reads as above-normal at a glance. Compute it from the **user's own data**
(e.g. the interquartile range of the shown period) — never an external
prescription dressed up as a target. LiftKit uses this on the training-load chart.

## 7. Static vs. interactive by size

Apple's rule, worth keeping:

- **Small inline charts** (sparkline rows, trend platters) stay calm: no axes, no
  gridlines, no interactivity — detail is one tap away.
- **Full detail charts** get the axis, and interactivity: a scrub read-out
  (`.chartXSelection` + a rule/callout snapped to the nearest real entry) for
  reading exact values.

## Porting checklist for RunKit / FuelKit

1. Copy the `LKChart` / `LKChartBucket` / `LKAggPoint` types and the
   `.lkTimeAxis(days:)` modifier (rename the `LK` prefix per app if you like, but
   keep the behavior identical).
2. Route every time-series chart through `.lkTimeAxis` + `.chartXScale`.
3. Aggregate by range (§1) with the right reducer; keep 1-week per-entry.
4. Dots: line-colored, ringed, on real entries only (§3).
5. Noisy metrics (RunKit resting HR / weight; FuelKit weight): trend + rate (§4).
6. Split charts (RunKit activity types; FuelKit macros): dim-to-focus legend (§5).
7. Match the app's own accent + semantic palette in `categorical`.
