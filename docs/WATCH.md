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
| next | `HKWorkoutSession` + `HKLiveWorkoutBuilder`, watch GPS, the card engine on-wrist, haptic card transitions, session transfer back to the phone. |
| later | The two-owner rule. Complications. Voice cues — the roadmap's open question is clip pack (bundle size, twice) vs system TTS; haptics carry v1 either way. |
