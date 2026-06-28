# RunKit — Requirements & Spec

> Status: **v0.01 — initial scaffold.** Living document.
> Platform: iOS 17+, SwiftUI + SwiftData. Built on Windows, archived via Codemagic.

---

## 1. The suite vision

RunKit is the second app in a family of small, focused, privacy-first fitness apps:

| App | Domain | Status |
|---|---|---|
| **LiftKit** | Strength / WOD timers + progression | Shipping (TestFlight) |
| **RunKit** | Walking / running / cycling — steps, distance, routes | **This project** |
| **FuelKit** *(working name)* | Food / nutrition logging | Future |

**What ties them together:**
- **Shared design language** — same theme tokens (gold accent, dark-first surfaces), typography, card styling, button styles. Today each app carries its own copy of the design system (`Theme.swift`); once stable, extract to a shared Swift package (`KitUI`).
- **HealthKit is the only integration bus.** Each app reads/writes the relevant HealthKit types (workouts, active energy, steps, bodyweight, nutrition). Calorie burn recorded by RunKit and LiftKit lands in Apple Health; FuelKit reads burn to inform calorie targets. **No app talks to another directly, and nothing goes through a server.**
- **Same product principles** (below).

**Non-goals for the suite:** accounts, social, friends, leaderboards, challenges, ads, third-party analytics/SDKs, cloud sync to anything but the user's own iCloud.

---

## 2. Product principles (in priority order)

1. **Privacy first.** All data is on-device. No accounts, no servers, no third-party SDKs, no tracking. Sensitive permissions (Location, Motion, Health) are **opt-in**, requested only when a feature needs them, with plain-language explanations. Because nothing leaves the device, the App Store privacy label is **"Data Not Collected"** — *including GPS routes*, which are stored locally and never transmitted.
2. **Lightweight.** Fast to open, one-glance dashboard, minimal taps. Small binary, low battery. No feature is added just because competitors have it.
3. **No social, ever.** No friends, no leaderboards, no challenges, no sharing-to-feed. Personal tool only.
4. **Honest estimates.** Calorie/distance numbers are labeled as estimates. Prefer Apple-provided data (HealthKit/Core Motion) over our own math where available.

---

## 3. Competitive read (what to include / exclude)

Benchmarked the privacy-first leaders (Pedometer++, StepsApp) against the heavier ones (Pacer, Steps).

**Include (lightweight table-stakes):**
- Live daily **step count**, **walking/running distance**, **flights climbed**, **active-calorie** estimate.
- A **daily goal** with a single **progress ring** (StepsApp's clean hero UI is the model).
- **Streaks** (consecutive days hitting goal).
- **History & trends** — week / month / year summaries with simple charts.
- **Widgets** (home + lock screen) — high value, modest cost. *Fast-follow (v1.1) — see roadmap.*
- **HealthKit** read (steps/distance/flights) + write (workouts + active energy).

**Include (this app's differentiator vs. pure pedometers — chosen scope):**
- **Activity sessions** — start a timed **Walk / Run / Ride** with **opt-in GPS** for real distance + a route map, live pace, and elevation. Saved as an `HKWorkout` with a route.

**Exclude (deliberately):**
- Social of any kind (friends, challenges, leaderboards, groups). ← hard line
- Accounts / login. Curated "explore routes/trails" content. In-app community.
- Heavy multi-sport catalogs (20+ types). RunKit ships Walk/Run/Ride only in v1.

---

## 4. RunKit v1 scope

### 4.1 Today (passive tracking) — *Core Motion, no permission beyond Motion*
- Hero **progress ring**: steps vs. daily goal.
- Stat tiles: **steps**, **distance** (walk/run), **flights**, **active calories** (estimate).
- Live updates from `CMPedometer` (today) + `HealthKit` (history backfill).

### 4.2 Activity session (active tracking) — *Walk / Run / Ride*
- Big timer (count-up) + live metrics.
- **Walk / Run:** distance from GPS when enabled, else Core Motion pedometer distance.
- **Ride:** distance from **GPS** (pedometer can't measure cycling). Without GPS, ride is timer-only with optional **manual distance** entry.
- **GPS is opt-in per session** (and globally toggleable). When on: route polyline on a map, live pace, elevation gain. Uses **When-In-Use** authorization + background location mode so it keeps recording with the screen off *during an active session only*.
- On finish: save an `ActivitySession` (+ `RoutePoint`s) locally and write an `HKWorkout` (+ route + active energy) to Health.

### 4.3 History & trends
- List of past sessions (type, duration, distance, calories, mini route thumbnail).
- Tap → detail (full route map, splits/pace, metrics; editable distance/notes).
- Trends: week/month/year totals (steps, distance, sessions, active days vs. goal).

### 4.4 Settings
- Daily step goal; units (imperial/metric) — shared convention with LiftKit.
- GPS default on/off; permission status + re-request shortcuts.
- Data management: export (CSV/GPX) + **Clear All Data** (with confirmation), mirroring LiftKit.
- About / Privacy / Disclaimer.

### 4.5 Explicitly deferred
- **Apple Watch app + complications** → v2 (where cardio really belongs; on-wrist GPS + HR). Same stance as LiftKit.
- Intervals/structured workouts, audio cues, advanced pace zones → v2.
- Premium tier (mirrors LiftKit's free/Plus split) → once v1 is stable.

---

## 5. Privacy & permissions

| Permission | When requested | Info.plist key |
|---|---|---|
| Motion & Fitness | First open of Today | `NSMotionUsageDescription` |
| Location (When-In-Use) | First time GPS session is started | `NSLocationWhenInUseUsageDescription` |
| HealthKit | First time reading/writing Health | `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription` |

- **Background location** mode (`UIBackgroundModes: location`) + `allowsBackgroundLocationUpdates` — only active while a session is running; stopped on finish. No "Always" authorization.
- `PrivacyInfo.xcprivacy`: `NSPrivacyTracking = false`, no tracking domains, **no collected data types** (on-device only), one required-reason API (`UserDefaults`, `CA92.1`).
- Encryption compliance: `ITSAppUsesNonExemptEncryption = false`.
- HealthKit capability in `RunKit.entitlements`.

---

## 6. Technical architecture

- **SwiftUI + SwiftData**, iOS 17+. CloudKit-compatible schema (non-optional attrs defaulted, relationships optional) so iCloud sync can be flipped on later (dormant by default, like LiftKit).
- **Core Motion** (`CMPedometer`) — passive steps/distance/flights, live during walk/run sessions.
- **Core Location** (`CLLocationManager`) — opt-in GPS route + distance for run/ride.
- **HealthKit** — read steps/distance; write `HKWorkout` + `HKWorkoutRoute` + active energy.
- **MapKit** — route polyline rendering.
- **Project generation: XcodeGen** (`project.yml`). No hand-maintained `.xcodeproj`; Codemagic runs `xcodegen generate` before archiving. Adding a Swift file requires zero project edits.
- **CI: Codemagic** — unsigned IPA workflow for AltStore (mirrors LiftKit) + a signed TestFlight workflow once enrolled.
- **Versioning:** `AppVersion.current` string bumped +0.01 per push (shared convention with LiftKit).

### Data model (initial)
- `ActivitySession` — id, type (walk/run/ride), startedAt, endedAt, activeSeconds, distanceMeters, steps?, flights?, activeEnergyKcal?, manualDistance flag, notes, usedGPS. Relationship → `[RoutePoint]`.
- `RoutePoint` — timestamp, latitude, longitude, altitude, horizontalAccuracy, speed. (Stored only when GPS used.)
- Daily goal / units / GPS-default → `@AppStorage`.

---

## 7. Roadmap

- **v1.0** — Today dashboard, Walk/Run/Ride sessions with opt-in GPS + route, history/trends, HealthKit read/write, settings, on-device privacy.
- **v1.1** — Widgets (home/lock), GPX/CSV export polish, StandBy.
- **v2.0** — Apple Watch app + complications, intervals/structured sessions, premium tier, optional iCloud sync activation.

---

## 8. Open decisions
- Final app icon / accent (currently inherits LiftKit gold).
- Bundle ID: `com.runkit.app` (placeholder, mirrors `com.liftkit.app`).
- Whether widgets ship in v1.0 or v1.1 (leaning 1.1 to keep v1 lean).
- When to extract the shared `KitUI` design package across LiftKit/RunKit/FuelKit.
