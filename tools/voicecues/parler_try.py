"""Try your own Parler voice samples. Loads the model once, then either does a
one-shot (--text ...) or an interactive loop where you type a description + line.
Output: out/try/<label>.m4a.

  one-shot : python parler_try.py --out warmup --text "Let's get moving!" --desc "..."
  loop     : python parler_try.py

The DESCRIPTION controls the voice (gender / accent / emotion / pace / pitch /
audio quality). The TEXT is the words. Tips at the bottom of this file.
"""
import argparse, os, subprocess, tempfile
import numpy as np, soundfile as sf, imageio_ffmpeg, torch
from parler_tts import ParlerTTSForConditionalGeneration
from transformers import AutoTokenizer, set_seed

REPO = "parler-tts/parler-tts-mini-v1"
FF = imageio_ffmpeg.get_ffmpeg_exe()
OUT = "out/try"
DEFAULT_DESC = ("A female speaker with a British accent speaks in an excited, upbeat and "
                "encouraging tone at a slightly fast pace. Very clear, high-quality, close-up recording.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", help="line to speak (omit for interactive mode)")
    ap.add_argument("--desc", default=DEFAULT_DESC, help="voice description")
    ap.add_argument("--out", default="try", help="output label -> out/try/<label>.m4a")
    ap.add_argument("--seed", type=int, help="repeatable voice/delivery (Parler is stochastic)")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    print("loading parler (once; ~1 min on CPU)...", flush=True)
    model = ParlerTTSForConditionalGeneration.from_pretrained(REPO).to("cpu")
    tok = AutoTokenizer.from_pretrained(REPO)
    sr = model.config.sampling_rate

    def synth(desc, text, label, seed=None):
        if seed is not None:
            set_seed(seed)
        ids = tok(desc, return_tensors="pt").input_ids
        pids = tok(text, return_tensors="pt").input_ids
        with torch.no_grad():
            out = model.generate(input_ids=ids, prompt_input_ids=pids)
        a = out.cpu().numpy().squeeze().astype(np.float32)
        a = a / (float(np.max(np.abs(a))) or 1.0) * 0.89
        w = os.path.join(tempfile.gettempdir(), "rk_try.wav")
        sf.write(w, a, sr)
        path = os.path.join(OUT, label + ".m4a")
        subprocess.run([FF, "-y", "-i", w, "-ac", "1", "-ar", str(sr),
                        "-c:a", "aac", "-b:a", "64k", path],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.remove(w)
        print(f"  -> {path}  ({len(a)/sr:.1f}s)", flush=True)

    if args.text:
        synth(args.desc, args.text, args.out, args.seed)
        return

    print("\nInteractive — blank label quits. Keep 'very clear, high-quality audio' in the description.\n")
    i = 1
    while True:
        try:
            label = input(f"[{i}] label (blank=quit): ").strip()
        except EOFError:
            break
        if not label:
            break
        desc = input("    description (blank=default): ").strip() or DEFAULT_DESC
        text = input("    line: ").strip()
        if not text:
            continue
        s = input("    seed (blank=random): ").strip()
        synth(desc, text, label, int(s) if s.lstrip("-").isdigit() else None)
        i += 1
    print("done -> out/try/")


if __name__ == "__main__":
    main()

# ── Description recipe (mix and match) ───────────────────────────────────────
#   gender   : "A female speaker" / "A male speaker"
#   accent   : "with a British accent" / "American" / "Australian"
#   emotion  : excited · upbeat · cheerful · warm · calm · enthusiastic · monotone
#   pace     : "at a fast pace" / "slowly" / "at a moderate pace"
#   pitch    : "high-pitched" / "low-pitched"           (optional)
#   QUALITY  : always add "Very clear, high-quality, close-up recording."  ← avoids
#              muffled/echoey output. This matters a lot.
# Tips:
#   • Parler is stochastic — run a line 2–3 times (or with --seed N) and keep the best.
#   • Punctuation drives delivery: "Nice work! You're flying!" > "Nice work, you're flying."
#   • Keep lines short (a phrase, not a paragraph).
