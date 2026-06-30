#!/usr/bin/env python3
"""
Render the voice cue pack from manifest.json — runs on Windows, no Mac needed.

Because RunKit's announcements are a fixed, non-responsive comment set, the audio
can be generated once, offline, with a high-quality neural voice and shipped as
files (the app never runs a model). This uses Kokoro (Apache-2.0, on-device-class,
pip-installable) by default; swap `synthesize` for any TTS (incl. a build-time
cloud API) if you prefer.

Setup (Windows):
    pip install kokoro soundfile numpy
    winget install Gyan.FFmpeg        # or: choco install ffmpeg
Run:
    RK_VOICE=bf_emma python generate.py
Then copy out/*.m4a into RunKit/Resources/VoiceCues/ and `xcodegen generate`.
"""
import json
import os
import subprocess
import sys

import numpy as np
import soundfile as sf

SR = 24000
OUT = "out"
VOICE = os.environ.get("RK_VOICE", "bf_emma")   # bf_*/bm_* British, af_*/am_* American, etc.
LANG = os.environ.get("RK_LANG", VOICE[0])      # 'b' British, 'a' American

# --- TTS backend: kokoro-onnx (no torch; installs cleanly on Python 3.14) -------
# Needs the model files next to this script (gitignored; download from
# https://github.com/thewh1teagle/kokoro-onnx releases, tag model-files-v1.0):
#   kokoro-v1.0.onnx, voices-v1.0.bin
# Swap this function for any other model or a build-time cloud API if preferred.
from kokoro_onnx import Kokoro
_KLANG = "en-gb" if LANG == "b" else "en-us"
_kokoro = Kokoro("kokoro-v1.0.onnx", "voices-v1.0.bin")

def synthesize(text: str) -> np.ndarray:
    """Return a mono float32 waveform at SR for `text`."""
    samples, _sr = _kokoro.create(text, voice=VOICE, speed=1.0, lang=_KLANG)
    return np.asarray(samples, dtype=np.float32).flatten()

# --- post-processing -----------------------------------------------------------
def trim_silence(audio: np.ndarray, thresh: float = 0.01, pad_s: float = 0.02) -> np.ndarray:
    loud = np.where(np.abs(audio) > thresh)[0]
    if loud.size == 0:
        return audio
    pad = int(pad_s * SR)
    return audio[max(0, loud[0] - pad): min(len(audio), loud[-1] + pad)]

def normalize_peak(audio: np.ndarray, peak: float = 0.97) -> np.ndarray:
    m = float(np.max(np.abs(audio))) or 1.0
    return audio * (peak / m)

def _ffmpeg_exe() -> str:
    from shutil import which
    if which("ffmpeg"):
        return "ffmpeg"
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()   # downloads a static binary on first use
    except Exception:
        return "ffmpeg"

_FFMPEG = _ffmpeg_exe()

def encode_m4a(wav_path: str, m4a_path: str) -> None:
    subprocess.run(
        [_FFMPEG, "-y", "-i", wav_path, "-c:a", "aac", "-b:a", "48k", "-ac", "1", "-ar", str(SR), m4a_path],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

# --- main ----------------------------------------------------------------------
def main() -> None:
    with open("manifest.json", encoding="utf-8") as f:
        manifest = json.load(f)
    os.makedirs(OUT, exist_ok=True)
    total = len(manifest)
    for i, (clip_id, text) in enumerate(manifest.items(), 1):
        audio = normalize_peak(trim_silence(synthesize(text)))
        wav = os.path.join(OUT, clip_id + ".wav")
        m4a = os.path.join(OUT, clip_id + ".m4a")
        sf.write(wav, audio, SR)
        encode_m4a(wav, m4a)
        os.remove(wav)
        print(f"[{i}/{total}] {clip_id}: {text!r}")
    print(f"done — {total} clips in {OUT}/  (voice: {VOICE})")

if __name__ == "__main__":
    try:
        main()
    except FileNotFoundError as e:
        sys.exit(f"missing dependency or file: {e}")
