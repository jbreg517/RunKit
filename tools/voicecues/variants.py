"""Render prosody/pacing variants of one motivational line for A/B listening.
Output: out/variants/*.m4a  (gitignored). Run from tools/voicecues with the venv.
"""
import os, subprocess, tempfile
import numpy as np, soundfile as sf
from kokoro_onnx import Kokoro
import imageio_ffmpeg

FF = imageio_ffmpeg.get_ffmpeg_exe()
SR = 24000
k = Kokoro("kokoro-v1.0.onnx", "voices-v1.0.bin")
OUT = "out/variants"
os.makedirs(OUT, exist_ok=True)


def lang(v):
    return "en-gb" if v[0] == "b" else "en-us"


def render(label, text, voice="bf_emma", speed=1.0):
    s, _ = k.create(text, voice=voice, speed=speed, lang=lang(voice))
    a = np.asarray(s, dtype=np.float32).flatten()
    a = a / (float(np.max(np.abs(a))) or 1.0) * 0.89
    wav = os.path.join(tempfile.gettempdir(), label + ".wav")
    sf.write(wav, a, SR)
    subprocess.run([FF, "-y", "-i", wav, "-ac", "1", "-ar", str(SR),
                    "-c:a", "aac", "-b:a", "64k", os.path.join(OUT, label + ".m4a")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(wav)
    print(f"  {label}: voice={voice} speed={speed}  {text!r}")


# Same line, varying punctuation / pacing / voice.
render("1_base",            "Nice work — you're flying.")                       # current style
render("2_excite",         "Nice work! You're flying!")                         # exclamation = brighter
render("3_beat",           "Nice work... you're flying!", speed=0.97)           # a beat before the payoff
render("4_warm_slow",      "Nice work — you're flying!", speed=0.90)            # slower = warmer
render("5_excite_fast",    "Nice work! You're flying!", speed=1.08)             # quicker = peppier
render("6_voice_afheart",  "Nice work! You're flying!", voice="af_heart")       # warmer voice (US)
render("7_voice_isabella", "Nice work! You're flying!", voice="bf_isabella")    # brighter British
print("done -> out/variants/")
