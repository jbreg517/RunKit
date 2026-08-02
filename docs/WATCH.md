# Apple Watch app

Roadmap item 3.6. Landed in stages from v0.51.

## The decision: the watch records

Two architectures were on the table.

**Watch as remote** — the watch sends "start", the phone records. Cheap (~2 days),
and rejected. RunKit's session engine lives *inside* `ActivitySessionView`, a
SwiftUI view presented as a `fullScreenCover`. `sendMessage` can wake the iOS app
in the background, but a view-driven engine starting reliably while the phone is
locked in a pocket is not something to bet on — and it doesn't deliver the actual
point of a running watch, which is leaving the phone behind.

**Watch records, phone archives** — chosen. It also fixes two things that are
currently held together with tape:

- `LiveHeartRateService` polls HealthKit on a trailing 90-second window every 10s.
  `HKLiveWorkoutBuilder` hands over ~1 Hz HR directly.
- The `heartRate` card goal only works today if *some other app* happens to be
  recording HR. RunKit ships an HR zone target it frequently cannot measure.

### The two-owner rule

Once both devices can record, they must not both record the same run: that produces
two workouts in Apple Health and doubled active energy, which then flows into
FuelKit's calorie targets as real data.

**Whichever device the user tapped Start on owns the session.** The other shows
"recording on your Watch" (or on your iPhone) and offers nothing else. This needs a
live state channel, which the menu sync below is *not*.

## What syncs, and how

| Direction | Content | Mechanism | Why that one |
|---|---|---|---|
| Phone → Watch | the menu | `updateApplicationContext` | State, not events. Last-wins, coalesced by the system, and `receivedApplicationContext` persists it across relaunch for free — so the watch needs no store of its own |
| Watch → Phone | finished session | `transferUserInfo` | Must not be lost; ordering doesn't matter |
| Watch → Phone | GPS route | `transferFile` | A 60-minute run at 1 Hz is ~250 KB — past what a message payload will take |

Not App Groups (they don't cross devices). Not iCloud (privacy stance).

## Shared code

The watch links the **real** card model rather than a translated copy, so the two
devices can't drift in how they interpret a workout:

```
RunKit/Models/ActivitySegment.swift    the cards themselves
RunKit/Enums/ActivityType.swift
RunKit/Enums/WorkoutType.swift
RunKit/Enums/WorkoutRecipe.swift       the prebuilt library
RunKit/Services/UnitSystem.swift
RunKit/Shared/WatchMenu.swift          the wire format
```

`CustomWorkout` (the SwiftData `@Model`) was split out of `ActivitySegment.swift`
into its own file in v0.51 precisely so that file could stay pure Foundation. Target
membership is an explicit per-file list in `project.yml`, not a folder glob — most
of `RunKit/` imports UIKit or SwiftData and will not compile for watchOS, so
membership has to stay reviewable.

`Theme.swift` is **not** shared: it builds dynamic light/dark colors out of
`UIColor`, which doesn't exist in usable form on watchOS. `RunKitWatch/Theme/`
carries the same tokens resolved statically to the dark palette, since watchOS has
no light appearance to switch to.

Wire format rule, same as the Live Activity: **every field decodes with
`decodeIfPresent`**. The watch app and the phone app update on independent
schedules, so a watch running last month's build will be handed today's payload, and
a synthesized decoder throws on any absent key — that would empty the menu rather
than degrade it.

## Screens

Three, deliberately. History, stats, settings and the card builder are all one tap
away on a phone that's already in the room, and none of them are things anyone wants
to operate on a 45 mm screen mid-warm-up.

1. **Root menu** — today's scheduled run (gold-edged, not gold-filled, so it doesn't
   compete with Start for the one filled accent on screen), Start Run, Walk/Ride
   two-up, then Prebuilt and My Workouts.
2. **Workout list** — prebuilt grouped by the five existing categories; saved
   workouts flat with favourites first.
3. **Start confirm** — name, summary, the cards in order, one gold Start.

`hasSynced` distinguishes "never synced" from "you haven't saved anything". Only the
first justifies telling the user to go open their phone.

## Build

Third App ID: `com.ferrixguild.runkit.watchkitapp`. Apple requires it to be a
prefix-extension of the host app's ID.

Traps, all of them load-bearing:

- `settings.base` sets `TARGETED_DEVICE_FAMILY: "1,2"`. The watch target **must**
  override to `"4"` or it builds fine and then won't install.
- The embed needs an explicit `copy.subpath` of `$(CONTENTS_FOLDER_PATH)/Watch`.
  Without it XcodeGen embeds the watch app like a framework and the archive fails
  validation.
- `WKApplication` = YES plus `WKCompanionAppBundleIdentifier` in the watch
  `Info.plist`. The old two-target `WKWatchKitApp` layout is gone as of watchOS 9.
- The watch profile type is `IOS_APP_STORE`. App Store Connect registers watchOS
  bundle IDs under platform `IOS`, and there is **no** `WATCH_APP_STORE` type — the
  platform-specific variants are `MAC_*` and `TVOS_*` only. `fetch-signing-files`
  also prefix-matches the bundle ID unless given `--strict-match-identifier`, so the
  call for `com.ferrixguild.runkit` already picks up both extensions.
- `WKBackgroundModes` takes **exactly one** session mode. `workout-processing`,
  `location`, `self-care`, `mindfulness`, `physical-therapy` and `alarm` are mutually
  exclusive — watchOS grants one kind of extended runtime session, not a set — and
  declaring two fails App Store upload validation with error 90362. Only
  `workout-processing` is needed here: the live `HKWorkoutSession` keeps the app out
  of suspension, so GPS keeps arriving with the wrist down. For the same reason
  `allowsBackgroundLocationUpdates` is never set — it requires the `location` mode
  and throws at runtime without it.
- Every embedded bundle must report the **same version** as the host app, so
  `RunKitWatch/Info.plist` is in the PlistBuddy mirroring loop in both workflows. A
  mismatch is a hard App Store validation rejection.

## TestFlight

The watch app is **not** a separate TestFlight build. It ships inside the iOS `.ipa`
and appears as one version; testers install the phone app and the watch app installs
to a paired watch automatically.

- Review needs a working demo path on a paired watch. Reviewers often test in the
  simulator, where nothing has synced — a blank menu reads as broken, so the
  unsynced state has to look deliberate.
- Recording adds the `workout-processing` background mode and a watch-side HealthKit
  entitlement. The "Data Not Collected" label stays accurate (nothing leaves the
  device), but the privacy manifest and Health usage strings need a pass.

## Status

| | |
|---|---|
| v0.51 | Target, theme, menu, phone→watch sync. Start is inert — this build exists to prove the target compiles, signs and installs before ~1000 lines of HealthKit go into it. |
| v0.52 | Signing fix: watch profiles are `IOS_APP_STORE`. |
| v0.53 | Recording. `HKWorkoutSession` + `HKLiveWorkoutBuilder`, live HR, watch GPS for the route, the full card engine on-wrist, haptic cues, run transferred back to the phone. |

### Recording notes

**Distance comes from HealthKit, not from summing `CLLocation`.** The watch fuses
GPS with wrist motion far better than a raw coordinate sum, and it's the only source
of real-time heart rate. Location is still collected, but *only* to draw the route.

**HR zone bounds are resolved on the phone** and shipped in the menu payload — that's
the side holding the max-HR override, the age from the suite profile, and a resting
HR from Health. The watch derives the five bounds from `maxHR`/`restingHR` so a
heart-rate card is judged against the same numbers on both devices.

**Zone seconds are accumulated at 1 Hz while unpaused**, which sidesteps the
gap-attribution problem `HeartRateZones.summarize` has to solve when the phone
re-reads irregular samples after the fact. Average BPM accumulates *separately* from
the zone buckets, so a phone that never synced a max HR costs the zone breakdown but
not the heart rate itself.

**The phone must never re-save an imported run to HealthKit.** The watch already
wrote it, with its route. Saving again duplicates the workout and doubles the active
energy, which then flows into FuelKit as real intake headroom. `hrCheckedAt` is
stamped on import for the same reason — it's what stops `HeartRateBackfill`
overwriting a wrist-measured summary with a worse re-query.

**Transfers are idempotent on `WatchSessionPayload.id`.** WatchConnectivity can
deliver a queued file more than once; without the id check the same run lands twice.
| v0.53 | Post-run summary, split marks, and a real failure screen. |
| — | Competitive pass against Apple Workout and Nike: auto-pause (product-wide, phone included), Always-On display, the two-owner rule, live HR zone + target feedback, splits/cadence/elevation, crash recovery. |
| later | Complications. Voice cues — the roadmap's open question is clip pack (bundle size, twice) vs system TTS; haptics carry v1 either way. Apple-hardware-specific running power and stride metrics are deliberately not chased. |

## Things that look like details and aren't

**Auto-pause needs GPS to keep running while paused.** A *manual* pause suspends the
receiver — the user has stopped on purpose, so that saves battery and avoids drift.
An *automatic* pause must not, because measuring speed is the only way to know the
run has started again. Hence `holdTracking`/`releaseTracking` alongside
`pauseTracking`/`resumeTracking` on the phone: held, fixes keep arriving and keep
updating speed while distance, route and gap detection stay frozen.

**Auto-pause is gated on 20m covered.** Speed reads 0 until the first fix lands,
which would otherwise pause every run about five seconds in.

**Always-On means the clock cannot be a normal label.** The app is throttled to
roughly one refresh a minute, so anything built from `elapsed` freezes.
`Text(timerInterval:)` is rendered by the system — the same trick the Live Activity
uses — which needs a start date with paused time already subtracted, re-anchored on
every resume.

**Elevation uses a moving reference, not the previous fix.** Per-fix thresholds fail
both ways: too low and a wandering receiver reports a hundred metres of climb on a
flat track, too high and a gradual hill — which rises less than the noise floor
between fixes — is discarded entirely.

**The two-owner signal is a guard, not a lock.** It only arrives when the devices are
in contact, so it states the conflict rather than blocking. A block that depended on
connectivity would strand the exact user the watch app exists for.

**Indoor is a property of the session, not the workout.** The same 5K is run outside
one day and on a treadmill the next; storing it on the template would be wrong on one
of those days. It drives `HKMetadataKeyIndoorWorkout` — without that key a treadmill
run is filed as an ordinary one, and its pace gets compared against outdoor efforts it
has nothing to do with.

**Auto-pause must be off indoors.** This was a live bug, not a hypothetical: with no
GPS, `latestSpeed` sits at 0, and auto-pause would have stopped the whole run twenty
metres in. Indoor speed comes from wrist-estimated distance instead, which is far too
coarse to tell "standing on the belt" from "running slowly".

**Pace indoors needs a longer window.** Motion-derived distance advances in coarse
jumps, so the GPS path's 3-second smoothing turns them into a pace that swings wildly.
Twenty seconds. The phone had the same bug in reverse — with GPS off it read
`location.currentSpeedMps`, which is always zero, so every treadmill run showed "--"
for its whole duration while happily counting distance.

**Crash recovery needs both halves.** `recoverActiveWorkoutSession` returns the live
session with distance, HR and energy intact, but everything RunKit layers on top —
card position, interval rep, zone buckets, splits — dies with the process. That's
snapshotted to `UserDefaults` on every card change and every 30 seconds. A live
session with *no* saved state is ended rather than resumed: the run is already safe
in HealthKit, and resuming it as a shapeless one would produce a wrong record.

## Phone independence

Recording needs no phone. Nothing in the path calls `isReachable` or `sendMessage`;
the only WatchConnectivity call is `transferFile`, which queues to disk and retries
when the phone reappears. All six card goals run on-wrist across walk, run and ride.

Two things *do* depend on a prior sync, and neither breaks a run:

- **The workout library.** Start Run / Walk / Ride are generated locally and always
  work. Prebuilt, saved and scheduled workouts arrive in the application context —
  once synced they persist offline indefinitely.
- **HR zone bounds.** Never synced means an HR card still runs to its length, but
  won't nudge, because it has no zone to judge against.
