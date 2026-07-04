"""Clone each out/refs/*.wav through Chatterbox (expressive) to compare accents/
voices. Run with the 3.12 venv after make_refs.py. Output: out/voices/*.m4a."""
import os, glob, subprocess, tempfile
import numpy as np, soundfile as sf, imageio_ffmpeg

import perth
if getattr(perth, "PerthImplicitWatermarker", None) is None:
    class _NoWatermark:
        def apply_watermark(self, wav, *a, **k):
            return wav
    perth.PerthImplicitWatermarker = _NoWatermark

from chatterbox.tts import ChatterboxTTS

FF = imageio_ffmpeg.get_ffmpeg_exe()
OUT = "out/voices"
os.makedirs(OUT, exist_ok=True)
model = ChatterboxTTS.from_pretrained(device="cpu")
SR = int(model.sr)
TEXT = "Nice work! You're flying!"


def encode(label, wav):
    a = wav.squeeze().detach().cpu().numpy().astype(np.float32)
    a = a / (float(np.max(np.abs(a))) or 1.0) * 0.89
    w = os.path.join(tempfile.gettempdir(), "rk_" + label + ".wav")
    sf.write(w, a, SR)
    subprocess.run([FF, "-y", "-i", w, "-ac", "1", "-ar", str(SR),
                    "-c:a", "aac", "-b:a", "64k", os.path.join(OUT, label + ".m4a")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(w)
    print(" ", label, flush=True)


encode("cb_default", model.generate(TEXT, exaggeration=0.7, cfg_weight=0.4))
for ref in sorted(glob.glob("out/refs/*.wav")):
    label = "cb_" + os.path.splitext(os.path.basename(ref))[0]
    encode(label, model.generate(TEXT, audio_prompt_path=ref, exaggeration=0.7, cfg_weight=0.4))
print("DONE -> out/voices/", flush=True)
