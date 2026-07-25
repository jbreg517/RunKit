// Turn the supplied winged-shoe mockup into an App Store compliant RunKit icon.
//
// Source problems fixed here:
//   1. "AI-Generated" watermark badge (x857..1013, y9..50)  -> keyed out
//   2. "LIFTKIT" wordmark (x353..706, y~825..885)           -> keyed out, RUNKIT drawn
//   3. Baked-in rounded corners + black margin              -> full-bleed square
//      (Apple applies the corner mask itself; shipping pre-rounded art yields
//       dark wedges in the corners on device)
//   4. Alpha channel                                        -> flattened to RGB
//
// Approach: the source is AI-generated and carries fine grain, so painting flat
// patches over regions leaves visible rectangles. Instead we rebuild the
// background wholesale — derive a coverage mask from luminance (the gold art is
// ~183 lum against a ~23 lum card), then recomposite the art over a fresh,
// clean backdrop. Grain, rounded corners, margin, badge and old wordmark all
// disappear in one pass, and the art keeps its antialiased edges.
const sharp = require('sharp');

const SRC = 'C:/Users/Jkbre/OneDrive/Documents2/RunKit/IMG_3613.PNG';
const GOLD = '#DBB564';                 // measured wing/wordmark gold
const S = 1024;

// Fresh backdrop: subtle vignette for depth, centred on the measured card colour.
const BG_CENTRE = [0x1C, 0x1B, 0x21];
const BG_EDGE   = [0x12, 0x11, 0x16];

// Luminance ramp separating art from background.
const LO = 32, HI = 62;

// Regions forced to background regardless of luminance.
const KILL = [
  { x0: 800, y0: 0,   x1: 1024, y1: 86  },  // AI-Generated badge
  { x0: 240, y0: 786, x1: 800,  y1: 928 },  // LIFTKIT wordmark
];

const withText = process.argv.includes('--text');
const OUT = process.argv[2] && !process.argv[2].startsWith('--') ? process.argv[2] : 'runkit-icon.png';

(async () => {
  const { data, info } = await sharp(SRC).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const W = info.width, H = info.height, C = info.channels;
  const out = Buffer.alloc(W * H * 3);

  const cx = W / 2, cy = H / 2, maxR = Math.hypot(cx, cy);

  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * C;
      const r = data[i], g = data[i + 1], b = data[i + 2];

      // Coverage: how much of this pixel is artwork.
      let a = (0.2126 * r + 0.7152 * g + 0.0722 * b - LO) / (HI - LO);
      a = a < 0 ? 0 : a > 1 ? 1 : a;
      a = a * a * (3 - 2 * a);                       // smoothstep, keeps edges soft
      for (const k of KILL) if (x >= k.x0 && x < k.x1 && y >= k.y0 && y < k.y1) a = 0;

      // Fresh backdrop with a gentle radial vignette.
      const t = Math.hypot(x - cx, y - cy) / maxR;
      const o = (y * W + x) * 3;
      for (let c = 0; c < 3; c++) {
        const bg = BG_CENTRE[c] + (BG_EDGE[c] - BG_CENTRE[c]) * t;
        out[o + c] = Math.round(data[i + c] * a + bg * (1 - a));
      }
    }
  }

  const layers = [];
  if (withText) {
    // Wordmark matched to the original band: cap height ~60px, baseline ~884, centred.
    layers.push({
      input: Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}">
        <text x="512" y="884" text-anchor="middle"
              font-family="Segoe UI Black, Arial Black, Impact, sans-serif"
              font-size="82" font-weight="900" letter-spacing="10"
              fill="${GOLD}">RUNKIT</text>
      </svg>`),
      top: 0, left: 0,
    });
  }

  let pipe = sharp(out, { raw: { width: W, height: H, channels: 3 } });
  if (layers.length) pipe = pipe.composite(layers);

  await pipe
    .removeAlpha()                     // App Store rejects icons with an alpha channel
    .toColourspace('srgb')
    .png({ compressionLevel: 9 })
    .toFile(OUT);

  const m = await sharp(OUT).metadata();
  const ok = m.width === S && m.height === S && !m.hasAlpha && m.channels === 3;
  console.log(`${OUT}: ${m.width}x${m.height} channels=${m.channels} alpha=${m.hasAlpha} space=${m.space}`);
  console.log(ok ? 'PASS: App Store icon requirements met' : 'FAIL');
})();
