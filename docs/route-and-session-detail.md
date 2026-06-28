# RunKit — Route Recording & Session Detail

> Feature spec for the GPS route + the session detail screen. Companion to
> [`REQUIREMENTS.md`](REQUIREMENTS.md). Status: **designed, not yet built.**

This covers two linked pieces:
1. **Route recording** — capturing and storing the GPS path during an active session.
2. **Session detail** — the screen you reach by tapping a past activity in History.

Everything stays **on-device**. Routes are never transmitted; the only way data
leaves the phone is a user-initiated export (GPX) or the workout/route the user
chooses to write into Apple Health.

---

## 1. Route recording

### 1.1 Data model (exists)
`RoutePoint` (already in the schema) stores one accepted GPS fix:

| Field | Meaning |
|---|---|
| `timestamp` | fix time (drives splits + pace) |
| `latitude` / `longitude` | position |
| `altitude` | metres, for elevation gain |
| `horizontalAccuracy` | metres; used to filter noise |
| `speed` | m/s reported by Core Location (≥0) |
| `session` | parent `ActivitySession` (cascade delete) |

`ActivitySession.route` holds the points; `sortedRoute` returns them in time order.

### 1.2 Recording flow
`LocationService` already accumulates distance and exposes `onPoint`. During an
active session (`ActivitySessionView.start()`), each accepted fix is persisted as
a `RoutePoint` linked to the session (already wired in v0.01).

Acceptance / smoothing rules (in `LocationService`, partly present):
- Reject fixes with `horizontalAccuracy < 0` (invalid) or `> 50 m` (noisy).
- Ignore movement `< 1 m` from the previous fix (GPS jitter while standing still).
- `desiredAccuracy = kCLLocationAccuracyBest`, `activityType = .fitness`,
  `distanceFilter = 5 m`.

**Sampling / storage cost:** at best accuracy a fix arrives roughly every 1–5 s.
A 1-hour run ≈ 700–3,600 points — fine for SwiftData. No periodic save during the
session; points are inserted into the context and persisted once on `finish()`
(single `context.save()`), keeping writes cheap.

**Battery:** continuous best-accuracy GPS is the main cost. Mitigations already in
place: `distanceFilter`, `.fitness` activity type (lets the OS optimise), and
**recording only while a session is active** (`startTracking`/`stopTracking` toggle
`allowsBackgroundLocationUpdates`). No "Always" authorization — When-In-Use plus the
`location` background mode is enough because the user explicitly started the session.

**Pause/resume (future):** when session pause lands, also `stopUpdatingLocation()`
on pause and resume on unpause, so paused time adds neither distance nor points.

### 1.3 Indoor / no-GPS sessions
- If GPS is off for the session (`usedGPS == false`): no points recorded; distance
  comes from the pedometer (walk/run) or manual entry (ride). The detail screen
  shows **no map**, just metrics.
- If GPS is on but no usable fixes arrive (indoors): `route` is empty → treat like
  no-GPS for rendering; keep whatever distance the pedometer captured for walk/run.

---

## 2. Session detail screen (`SessionDetailView`)

Reached from a History row via `NavigationLink`. Read-only by default, with an
**Edit** mode (mirrors LiftKit's history-detail pattern).

### 2.1 Layout (top → bottom)
1. **Route map** (only when `route` has ≥2 points) — hero card, ~260 pt tall.
   - MapKit `Map { MapPolyline(coordinates:) .stroke(RKColor.accent, lineWidth: 4) }`.
   - Start pin (green) + end pin (accent). Camera fit to the route's bounding region
     with padding; non-interactive thumbnail that expands to fullscreen on tap.
2. **Summary tiles** — Distance · Duration · Avg Pace (or Avg Speed for rides).
3. **Secondary stats** — Active calories, Elevation gain, Steps (walk/run only),
   Avg/Max speed.
4. **Splits** — per-km (metric) or per-mile (imperial) rows: split #, time, pace,
   a small relative-effort bar. Hidden when no route/distance.
5. **Notes** — free text (editable).
6. **Actions** — Do Again (prefills a new session of the same type), Export GPX,
   Delete (with confirmation).

### 2.2 Metrics & formulas
- **Distance:** `session.distanceMeters` (GPS sum, pedometer, or manual).
- **Duration:** `session.activeSeconds`.
- **Avg pace** (walk/run): `duration / distanceKm` → `mm:ss /km` (or `/mi`).
- **Avg speed** (ride): `distanceKm / hours` → `km/h` (or `mph`).
- **Splits:** walk the sorted route accumulating distance; each time the cumulative
  distance crosses a unit boundary (1 km / 1 mi), record the elapsed time since the
  previous boundary → that split's time/pace. Final partial split shown as partial.
- **Elevation gain:** sum of positive `altitude` deltas between consecutive points,
  with a small threshold (ignore deltas `< 1 m`) to damp barometer/GPS noise.
- **Max speed:** max of point `speed` values (filter outliers > plausible cap per type).

### 2.3 Editing (Edit mode)
Staged drafts, applied on Save (same approach as LiftKit's `WorkoutDetailView`):
- **Distance** — editable for **rides** and any **manual/no-GPS** session (sets
  `manualDistance = true`). GPS distance is read-only (derived from the route).
- **Activity type** — change walk/run/ride.
- **Notes** — free text.
- **Delete** — removes the session (cascades route points).
Recompute calories on save via `HealthCalc.kcal`.

### 2.4 Units
Mirror LiftKit's `UnitSystem` (`@AppStorage("unitSystem")`):
- metric → km, `min/km`, km/h, metres.
- imperial → mi, `min/mi`, mph, feet.
Add a small `Pace`/`Distance` formatter helper (`Services/RouteMath.swift`).

---

## 3. Writing the route to Apple Health

Today `HealthService.save` writes an `HKWorkout` only. To attach the GPS route:

1. Add `HKSeriesType.workoutRoute()` to `writeTypes`.
2. Replace the deprecated `HKWorkout(...)` initializer with the builder flow:
   - `HKWorkoutBuilder(healthStore:device:)` → `beginCollection(at:)` →
     add distance/energy samples → `endCollection(at:)` → `finishWorkout()`.
   - Then `HKWorkoutRouteBuilder(healthStore:device:)` →
     `insertRouteData(sortedRoute → [CLLocation])` →
     `finishRoute(with: workout, metadata: nil)`.
3. Reconstruct `CLLocation`s from `RoutePoint`s (coordinate, altitude, accuracies,
   timestamp). This makes RunKit routes appear in Apple Fitness alongside the suite.

> Permission, battery, and on-device storage are unchanged — the route is written
> only to the user's own Health database, never to a server.

---

## 4. Rendering & performance notes
- **Downsample for display:** for very long routes, render every Nth point (target
  ~500 coordinates) so `MapPolyline` stays smooth. Keep all points in storage and
  for splits/elevation math; only the polyline is decimated.
- **Thumbnail in History:** a small static `Map` (or a snapshot) per completed,
  GPS-backed row, fit to its route. Cache snapshots if it costs scroll performance.
- **Empty/short routes:** 0–1 points → no map, no splits; show metrics only.

---

## 5. File plan (when implemented)
New:
- `Views/SessionDetailView.swift` — the screen above.
- `Views/RouteMapView.swift` — reusable polyline map (thumbnail + fullscreen).
- `Services/RouteMath.swift` — splits, elevation gain, downsampling, pace/distance/
  speed formatting + `UnitSystem`.

Changed:
- `Views/HistoryView.swift` — rows become `NavigationLink → SessionDetailView`; add
  optional route thumbnail.
- `Services/HealthService.swift` — `HKWorkoutBuilder` + `HKWorkoutRouteBuilder`,
  add `workoutRoute()` to write types.

No model changes needed — `RoutePoint` already captures everything.

---

## 6. Open questions
- Split unit follows the global metric/imperial setting — add a per-session override?
- GPX export in v1.0, or fold into the v1.1 export pass with CSV?
- Show a live mini-map during the active session, or only in detail afterwards?
  (Leaning detail-only for v1 to keep the active screen glanceable + save battery.)
