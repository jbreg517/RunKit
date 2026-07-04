"""Make short reference clips in several accents/genders with Kokoro (run with the
3.14 venv). These feed Chatterbox's voice cloning to get accent variety WITH
Chatterbox expressiveness. Output: out/refs/*.wav (gitignored)."""
import os
import numpy as np, soundfile as sf
from kokoro_onnx import Kokoro

k = Kokoro("kokoro-v1.0.onnx", "voices-v1.0.bin")
os.makedirs("out/refs", exist_ok=True)
REF = "I love running in the morning. The fresh air really keeps me going."

VOICES = {
    "brit_f":  ("bf_emma",     "en-gb"),
    "brit_m":  ("bm_george",   "en-gb"),
    "us_f":    ("af_heart",    "en-us"),
    "us_m":    ("am_michael",  "en-us"),
    "brit_f2": ("bf_isabella", "en-gb"),
}
for label, (voice, lang) in VOICES.items():
    s, _ = k.create(REF, voice=voice, speed=1.0, lang=lang)
    a = np.asarray(s, dtype=np.float32).flatten()
    a = a / (float(np.max(np.abs(a))) or 1.0) * 0.9
    sf.write(f"out/refs/{label}.wav", a, 24000)
    print("ref", label, voice)
print("done -> out/refs/")
