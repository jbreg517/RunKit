"""Parler-TTS samples: accent + emotion described in one natural-language prompt.
Run with the rk-parler venv. Output: out/parler/*.m4a (gitignored)."""
import os, subprocess, tempfile
import numpy as np, soundfile as sf, imageio_ffmpeg, torch
from parler_tts import ParlerTTSForConditionalGeneration
from transformers import AutoTokenizer

FF = imageio_ffmpeg.get_ffmpeg_exe()
OUT = "out/parler"
os.makedirs(OUT, exist_ok=True)
REPO = "parler-tts/parler-tts-mini-v1"

print("loading parler (downloads ~2.5 GB on first run)...", flush=True)
device = "cpu"
model = ParlerTTSForConditionalGeneration.from_pretrained(REPO).to(device)
tok = AutoTokenizer.from_pretrained(REPO)
SR = model.config.sampling_rate
print("sr =", SR, flush=True)

LINE = "Nice work! You're flying!"


def render(label, description, line=LINE):
    ids = tok(description, return_tensors="pt").input_ids.to(device)
    pids = tok(line, return_tensors="pt").input_ids.to(device)
    with torch.no_grad():
        gen = model.generate(input_ids=ids, prompt_input_ids=pids)
    a = gen.cpu().numpy().squeeze().astype(np.float32)
    a = a / (float(np.max(np.abs(a))) or 1.0) * 0.89
    w = os.path.join(tempfile.gettempdir(), "rk_" + label + ".wav")
    sf.write(w, a, SR)
    subprocess.run([FF, "-y", "-i", w, "-ac", "1", "-ar", str(SR),
                    "-c:a", "aac", "-b:a", "64k", os.path.join(OUT, label + ".m4a")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(w)
    print(" ", label, flush=True)


render("pl_brit_f_excited",  "A female speaker with a British accent speaks in an excited, upbeat and encouraging tone at a slightly fast pace. Very clear, high-quality, close-up recording.")
render("pl_brit_m_motivate", "A male speaker with a British accent speaks in an enthusiastic, motivating tone at a moderate pace. Very clear, high-quality audio.")
render("pl_us_f_cheerful",   "A female speaker with an American accent speaks cheerfully and energetically, like an upbeat fitness coach. Very clear, high-quality audio.")
render("pl_us_m_hype",       "A male speaker with an American accent speaks in an energetic, hyped, motivational tone at a fast pace. Very clear audio.")
print("DONE -> out/parler/", flush=True)
