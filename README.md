# RunKit

A lightweight, privacy-first walking / running / cycling tracker for iPhone — the
cardio sibling to **LiftKit**. Steps, distance, routes and calorie burn, all
on-device. No accounts, no servers, no social.

See [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) for the full spec and the suite
vision (LiftKit · RunKit · FuelKit), tied together only through Apple HealthKit.

## Principles
1. **Privacy first** — on-device only; sensitive permissions (Motion, Location,
   Health) are opt-in. Nothing is transmitted, so the App Store privacy label is
   *Data Not Collected* — including GPS routes.
2. **Lightweight** — one-glance dashboard, small and fast.
3. **No social** — no friends, leaderboards or challenges. Ever.

## Stack
- SwiftUI + SwiftData, iOS 17+
- Core Motion (`CMPedometer`) · Core Location (opt-in GPS) · HealthKit · MapKit
- **XcodeGen** — the `.xcodeproj` is generated from [`project.yml`](project.yml),
  not checked in. Adding a Swift file needs no project edits.

## Building (no Mac required)
Builds run on **Codemagic** (the dev machine is Windows). The CI workflow runs
`xcodegen generate` and then archives — see [`codemagic.yaml`](codemagic.yaml).

To generate the project locally on a Mac:
```sh
brew install xcodegen
xcodegen generate
open RunKit.xcodeproj
```

## Conventions
- `AppVersion.current` (in `RunKit/App/RunKitApp.swift`) is bumped +0.01 per push,
  matching LiftKit; CI derives the build number from the git commit count.
- Bundle ID: `com.runkit.app` (placeholder until enrollment).

## Status
v0.01 — initial scaffold. Today dashboard, activity sessions, services and config
in place; UI is a functional skeleton under active development.
