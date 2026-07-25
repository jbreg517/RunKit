# App icon pipeline

The shipped icon derives from `source-mockup.png` (an AI-generated winged-shoe
card, gold on near-black, matching the LiftKit theme). `build.js` converts that
mockup into an **App Store compliant** 1024 PNG.

## Run

```bash
npm install sharp
node build.js runkit-icon-wordmark.png --text   # winged shoe + RUNKIT wordmark
node build.js runkit-icon-mark-only.png         # winged shoe only
```

Copy the chosen output to
`RunKit/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.
There is no ImageMagick/rsvg on the build machine — `sharp` (npm) is the
rasterizer.

## What build.js fixes

| Source problem | Why it matters | Fix |
|---|---|---|
| "AI-Generated" watermark badge | Not shippable | Keyed out |
| "LIFTKIT" wordmark | Wrong app | Keyed out, RUNKIT drawn |
| Baked-in rounded corners + black margin | **iOS applies its own corner mask** — pre-rounded art shows dark wedges in the corners on device | Rebuilt full-bleed square |
| Alpha channel | App Store **rejects** icons with alpha | Flattened, `removeAlpha()` |

The mockup is AI-generated and carries fine grain, so painting flat patches over
regions left visible rectangles. `build.js` instead rebuilds the background
wholesale: it derives a coverage mask from luminance (gold art ≈183 lum against
a ≈23 lum card) and recomposites the art over a fresh vignetted backdrop. Grain,
corners, margin, badge and old wordmark all disappear in one pass while the art
keeps its antialiased edges.

The script asserts the output is 1024×1024, sRGB, 3-channel, no alpha.

## Wordmark vs. mark-only

`size-comparison.png` renders both at real device sizes (180/120/87/60/40 px)
with the iOS corner mask applied.

**Mark-only is the better icon** and matches Apple's HIG (avoid app-name text —
the name already renders directly beneath the icon):

- With the wordmark, "RUNKIT" is illegible at 60 px (Spotlight) and 40 px
  (notifications), and the wordmark steals vertical space so the shoe renders
  smaller at *every* size.
- Mark-only reads cleanly all the way down to 40 px.

Currently shipping the **mark-only** variant. To switch to the wordmark:

```bash
cp tools/icon/runkit-icon-wordmark.png RunKit/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```
