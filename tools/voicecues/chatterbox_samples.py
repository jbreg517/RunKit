"""Generate expressive samples with Chatterbox (Resemble AI, MIT) — which has an
emotion 'exaggeration' knob and pacing control ('cfg_weight'), unlike Kokoro.
Output: out/expressive/*.m4a (gitignored). Run from tools/voicecues with the 3.12 venv.
"""
import os, subprocess, tempfile
import numpy as np
import soundfile as sf
import imageio_ffmpeg

# resemble-perth's implicit watermarker can resolve to None on Windows and crash
# ChatterboxTTS.__init__. The watermark is an optional inaudible tag — stub it out.
import perth
if getattr(perth, "PerthImplicitWatermarker", None) is None:
    class _NoWatermark:
        def apply_watermark(self, wav, *a, **k):
            return wav
    perth.PerthImplicitWatermarker = _NoWatermark

from chatterbox.tts import ChatterboxTTS

FF = imageio_ffmpeg.get_ffmpeg_exe()
OUT = "out/expressive"
os.makedirs(OUT, exist_ok=True)

print("loading chatterbox (model cached after first run)...", flush=True)
model = ChatterboxTTS.from_pretrained(device="cpu")
SR = int(model.sr)
print("sr =", SR, flush=True)


def render(label, text, exaggeration=0.5, cfg_weight=0.5):
    wav = model.generate(text, exaggeration=exaggeration, cfg_weight=cfg_weight)
    a = wav.squeeze().detach().cpu().numpy().astype(np.float32)
    a = a / (float(np.max(np.abs(a))) or 1.0) * 0.89
    w = os.path.join(tempfile.gettempdir(), "rk_" + label + ".wav")
    sf.write(w, a, SR)
    subprocess.run([FF, "-y", "-i", w, "-ac", "1", "-ar", str(SR),
                    "-c:a", "aac", "-b:a", "64k", os.path.join(OUT, label + ".m4a")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(w)
    print(f"  {label}: exaggeration={exaggeration} cfg_weight={cfg_weight}", flush=True)


T = "Nice work! You're flying!"
# Emotion intensity (exaggeration) low -> high, with pacing (cfg_weight) tuned.
render("cb_1_neutral",    T, exaggeration=0.4, cfg_weight=0.5)
render("cb_2_warm_slow",  "Nice work. You're flying.", exaggeration=0.5, cfg_weight=0.3)
render("cb_3_expressive", T, exaggeration=0.7, cfg_weight=0.45)
render("cb_4_excited",    T, exaggeration=0.9, cfg_weight=0.4)
render("cb_5_hype",       T, exaggeration=1.3, cfg_weight=0.3)
render("cb_6_finishline", "Strong finish! Be proud of that one.", exaggeration=0.8, cfg_weight=0.4)
print("DONE -> out/expressive/", flush=True)
