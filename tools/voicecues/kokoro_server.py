"""Local web UI for Kokoro voice sampling — named voices with reliable accents
(bf_*/bm_* British, af_*/am_* American). Much faster than Parler on CPU and
deterministic. Stdlib HTTP only.

    python kokoro_server.py [--port 8766]

Controls exposed (everything Kokoro actually has — it has NO emotion/mood param;
mood comes from voice choice, blending, pacing, and line punctuation):
  - Voice A + optional Voice B with a blend slider (style vectors are mixable)
  - Speed (rate), Pitch shift in semitones (ffmpeg post-process)
  - Dialect override (US/GB phonemization)
Clips land in out/try/<label>.m4a alongside the Parler sampler's output.
"""
import argparse, json, os, re, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "try")
os.makedirs(OUT, exist_ok=True)

STATE = {"ready": False, "error": None, "busy": False}
MODEL = {}
GEN_LOCK = threading.Lock()


def voice_label(name):
    accent = {"a": "American", "b": "British"}.get(name[0], name[0])
    gender = {"f": "female", "m": "male"}.get(name[1], name[1])
    return f"{accent} {gender} — {name.split('_', 1)[1]} ({name})"


def load_model():
    try:
        import numpy as np
        from kokoro_onnx import Kokoro
        MODEL["kokoro"] = Kokoro(os.path.join(HERE, "kokoro-v1.0.onnx"),
                                 os.path.join(HERE, "voices-v1.0.bin"))
        MODEL["styles"] = np.load(os.path.join(HERE, "voices-v1.0.bin"))
        MODEL["voices"] = [n for n in sorted(MODEL["styles"].files) if n[:1] in "ab"]
        STATE["ready"] = True
    except Exception as e:
        STATE["error"] = f"{type(e).__name__}: {e}"


TAG_RE = re.compile(r"\[\s*(pause|pitch|speed|vol|voice)\s+([^\]]+?)\s*\]", re.IGNORECASE)


def parse_script(text):
    """Inline markup → segments. `[pause 0.5]` inserts exact silence. `[pitch +2]`,
    `[speed 1.1]`, `[vol 1.3]`, `[voice bm_george]` apply to the text that FOLLOWS
    (until changed); `[voice mix]` returns to the UI's A/B blend. Tags can sit
    between single words, so the speaker can change word by word. Returns
    [("silence", seconds) | ("speak", text, {pitch, speed, vol, voice})]."""
    segments, pos = [], 0
    cur = {"pitch": 0.0, "speed": 1.0, "vol": 1.0, "voice": None}

    def emit(chunk):
        chunk = chunk.strip()
        if chunk:
            segments.append(("speak", chunk, dict(cur)))

    for m in TAG_RE.finditer(text):
        emit(text[pos:m.start()])
        tag, val = m.group(1).lower(), m.group(2).strip()
        if tag == "pause":
            try:
                segments.append(("silence", min(3.0, max(0.05, float(val)))))
            except ValueError:
                pass
        elif tag == "voice":
            cur["voice"] = None if val.lower() in ("mix", "default", "a") else val.lower()
        else:
            try:
                v = float(val)
            except ValueError:
                v = None
            if v is not None:
                if tag == "pitch":
                    cur["pitch"] = min(6.0, max(-6.0, v))
                elif tag == "speed":
                    cur["speed"] = min(1.5, max(0.5, v))
                elif tag == "vol":
                    cur["vol"] = min(2.0, max(0.3, v))
        pos = m.end()
    emit(text[pos:])
    return segments


def pitch_shift(a, sr, semitones, ff):
    """Shift pitch without changing duration (ffmpeg asetrate + atempo)."""
    import numpy as np, soundfile as sf
    factor = 2 ** (semitones / 12.0)
    src = os.path.join(tempfile.gettempdir(), "rk_seg_in.wav")
    dst = os.path.join(tempfile.gettempdir(), "rk_seg_out.wav")
    sf.write(src, a, sr)
    subprocess.run([ff, "-y", "-i", src,
                    "-af", f"asetrate={int(sr * factor)},aresample={sr},atempo={1 / factor:.6f}",
                    dst], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out, _ = sf.read(dst, dtype="float32")
    os.remove(src)
    os.remove(dst)
    return out


def edge_fade(a, sr):
    """~8 ms linear fades so stitched fragments never click."""
    import numpy as np
    n = int(0.008 * sr)
    if a.size > 2 * n:
        a[:n] *= np.linspace(0, 1, n, dtype=np.float32)
        a[-n:] *= np.linspace(1, 0, n, dtype=np.float32)
    return a


def synthesize(voice, voice2, blend, text, label, speed, pitch, lang):
    import numpy as np, soundfile as sf, imageio_ffmpeg
    # Blend two style vectors when a second voice is chosen (blend = % of A).
    if voice2 and blend < 100:
        w = blend / 100.0
        mix_style = (MODEL["styles"][voice] * w + MODEL["styles"][voice2] * (1 - w)).astype(np.float32)
    else:
        mix_style = voice
    ff = imageio_ffmpeg.get_ffmpeg_exe()

    sr = 24000
    pieces = []
    for seg in parse_script(text) or [("speak", text, {"pitch": 0.0, "speed": 1.0, "vol": 1.0, "voice": None})]:
        if seg[0] == "silence":
            pieces.append(np.zeros(int(seg[1] * sr), dtype=np.float32))
            continue
        _, seg_text, st = seg
        # per-segment voice override; "mix"/None = the UI's A/B blend
        if st["voice"]:
            if st["voice"] not in MODEL["voices"]:
                raise ValueError(f"unknown [voice {st['voice']}] — see the dropdowns for valid names")
            seg_style, base = st["voice"], st["voice"]
        else:
            seg_style, base = mix_style, voice
        seg_lang = lang if lang != "auto" else ("en-gb" if base.startswith("b") else "en-us")
        samples, sr = MODEL["kokoro"].create(seg_text, voice=seg_style,
                                             speed=min(1.5, max(0.5, speed * st["speed"])), lang=seg_lang)
        a = np.asarray(samples, dtype=np.float32).flatten()
        total_pitch = pitch + st["pitch"]        # global knob + per-segment tag
        if abs(total_pitch) > 0.01:
            a = pitch_shift(a, sr, total_pitch, ff)
        a = edge_fade(a * st["vol"], sr)
        pieces.append(a)
        pieces.append(np.zeros(int(0.06 * sr), dtype=np.float32))  # natural micro-gap
    a = np.concatenate(pieces) if pieces else np.zeros(1, dtype=np.float32)
    a = a / (float(np.max(np.abs(a))) or 1.0) * 0.89

    wav = os.path.join(tempfile.gettempdir(), "rk_kui.wav")
    sf.write(wav, a, sr)
    path = os.path.join(OUT, label + ".m4a")
    subprocess.run([ff, "-y", "-i", wav, "-ac", "1", "-ar", str(sr),
                    "-c:a", "aac", "-b:a", "64k", path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(wav)
    return round(len(a) / sr, 1)


def list_clips():
    files = []
    for f in os.listdir(OUT):
        if f.endswith(".m4a"):
            p = os.path.join(OUT, f)
            files.append({"name": f, "kb": round(os.path.getsize(p) / 1024, 1),
                          "mtime": os.path.getmtime(p)})
    return sorted(files, key=lambda x: -x["mtime"])


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>RunKit Kokoro sampler</title>
<style>
  :root { color-scheme: dark; }
  body { font-family: -apple-system, "Segoe UI", sans-serif; background:#111; color:#eee;
         max-width: 720px; margin: 0 auto; padding: 16px; }
  h1 { font-size: 1.2em; color: #d4a843; }
  label { display:block; margin: 10px 0 4px; font-size: .85em; color:#aaa; }
  input, select { width: 100%; box-sizing: border-box; background:#1c1c1e; color:#eee;
         border: 1px solid #333; border-radius: 8px; padding: 8px; font-size: .95em; }
  input[type=range] { padding: 0; }
  .row { display: flex; gap: 10px; } .row > div { flex: 1; }
  .hint { font-size: .75em; color: #777; margin-top: 2px; }
  button { background:#d4a843; color:#000; font-weight: 600; border: 0; border-radius: 8px;
         padding: 10px 18px; margin-top: 14px; cursor: pointer; font-size: 1em; }
  button:disabled { background:#555; color:#999; cursor: default; }
  #status { margin-top: 10px; font-size: .9em; color:#d4a843; min-height: 1.2em; }
  .clip { background:#1c1c1e; border-radius: 8px; padding: 8px 12px; margin-top: 8px;
         display: flex; align-items: center; gap: 10px; }
  .clip .name { flex: 1; font-size: .9em; word-break: break-all; }
  .clip audio { height: 32px; max-width: 300px; }
  .err { color: #ef4444; }
  h2 { font-size: 1em; margin-top: 24px; color:#aaa; }
</style></head><body>
<h1>RunKit &mdash; Kokoro voice sampler</h1>
<div id="status">Checking model status&hellip;</div>

<div class="row">
  <div>
    <label>Voice A</label>
    <select id="voice"></select>
  </div>
  <div>
    <label>Voice B (optional &mdash; blend for tone)</label>
    <select id="voice2"><option value="">None</option></select>
  </div>
</div>
<label>Blend: <span id="blendval">100</span>% A / <span id="blendval2">0</span>% B</label>
<input id="blend" type="range" min="0" max="100" value="100" oninput="blendLabel()">
<div class="hint">Mix two voices to sculpt timbre &mdash; e.g. 60% bf_emma + 40% af_heart softens the accent and warms the tone. Cross-gender mixes shift pitch character.</div>

<label>Line to speak &mdash; inline tags: <code>[pause 0.5]</code> silence &middot; <code>[pitch +2]</code> / <code>[speed 1.1]</code> / <code>[vol 1.3]</code> / <code>[voice bm_george]</code> apply to what follows &middot; <code>[voice mix]</code> = back to the A/B blend</label>
<input id="text" placeholder="Nice work! [voice bm_george] Outstanding! [voice mix] [pitch +2] You're flying!" value="Kilometer three. [pause 0.5] Nice work! [voice bm_george] Outstanding! [voice mix] [pitch +2] You're flying!">
<div class="hint">Punctuation still matters (! adds energy). Tags can sit between single words, so the speaker can change word by word &mdash; but every tag splits the line into separately-rendered fragments, so heavy tagging reads choppy. Voice names for <code>[voice &hellip;]</code> are the codes in the dropdowns (bf_emma, am_michael, &hellip;).</div>

<div class="row">
  <div><label>Speed (0.7&ndash;1.3)</label><input id="speed" type="number" step="0.05" min="0.5" max="1.5" value="1.0"></div>
  <div><label>Pitch (semitones, -4&hellip;+4)</label><input id="pitch" type="number" step="0.5" min="-6" max="6" value="0"></div>
  <div><label>Dialect</label><select id="lang">
    <option value="auto">Auto (from Voice A)</option>
    <option value="en-us">American (en-us)</option>
    <option value="en-gb">British (en-gb)</option>
  </select></div>
</div>
<div class="row">
  <div><label>Label (file name)</label><input id="label" placeholder="take1"></div>
</div>
<button id="go" onclick="generate()" disabled>Generate</button>

<h2>Clips in out/try/ (newest first)</h2>
<div id="clips"></div>

<script>
function blendLabel() {
  const v = document.getElementById('blend').value;
  document.getElementById('blendval').textContent = v;
  document.getElementById('blendval2').textContent = 100 - v;
}
async function poll() {
  try {
    const s = await (await fetch('/api/status')).json();
    const st = document.getElementById('status');
    if (s.error) { st.innerHTML = '<span class="err">Model failed to load: ' + s.error + '</span>'; return; }
    if (!s.ready) { st.textContent = 'Loading model…'; setTimeout(poll, 1500); return; }
    if (s.voices && document.getElementById('voice').options.length === 0) {
      const a = document.getElementById('voice'), b = document.getElementById('voice2');
      s.voices.forEach(v => {
        const o = document.createElement('option'); o.value = v.name; o.textContent = v.label; a.appendChild(o);
        const o2 = o.cloneNode(true); b.appendChild(o2);
      });
      a.value = 'bf_emma';
    }
    document.getElementById('go').disabled = s.busy;
    st.textContent = s.busy ? 'Generating…' : 'Ready.';
    if (s.busy) setTimeout(poll, 1500);
  } catch (e) { setTimeout(poll, 1500); }
}
async function refreshClips() {
  const clips = await (await fetch('/api/clips')).json();
  const el = document.getElementById('clips');
  el.innerHTML = '';
  clips.forEach(c => {
    const d = document.createElement('div'); d.className = 'clip';
    d.innerHTML = '<div class="name">' + c.name + ' <span style="color:#777">(' + c.kb + ' KB)</span></div>' +
                  '<audio controls preload="none" src="/clips/' + encodeURIComponent(c.name) + '"></audio>';
    el.appendChild(d);
  });
}
async function generate() {
  const body = {
    voice: document.getElementById('voice').value,
    voice2: document.getElementById('voice2').value,
    blend: parseInt(document.getElementById('blend').value, 10),
    text: document.getElementById('text').value.trim(),
    label: document.getElementById('label').value.trim(),
    speed: parseFloat(document.getElementById('speed').value) || 1.0,
    pitch: parseFloat(document.getElementById('pitch').value) || 0,
    lang: document.getElementById('lang').value
  };
  if (!body.text) { alert('Enter a line to speak.'); return; }
  document.getElementById('go').disabled = true;
  document.getElementById('status').textContent = 'Generating…';
  try {
    const r = await fetch('/api/generate', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
    const j = await r.json();
    if (j.error) document.getElementById('status').innerHTML = '<span class="err">' + j.error + '</span>';
    else document.getElementById('status').textContent = 'Done: ' + j.file + ' (' + j.seconds + 's of audio)';
  } catch (e) {
    document.getElementById('status').innerHTML = '<span class="err">' + e + '</span>';
  }
  document.getElementById('go').disabled = false;
  refreshClips();
}
poll(); refreshClips();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif self.path == "/api/status":
            out = dict(STATE)
            if STATE["ready"]:
                out["voices"] = [{"name": v, "label": voice_label(v)} for v in MODEL["voices"]]
            self._send(200, out)
        elif self.path == "/api/clips":
            self._send(200, list_clips())
        elif self.path.startswith("/clips/"):
            name = os.path.basename(self.path[len("/clips/"):])
            p = os.path.join(OUT, name)
            if name.endswith(".m4a") and os.path.isfile(p):
                with open(p, "rb") as f:
                    self._send(200, f.read(), "audio/mp4")
            else:
                self._send(404, {"error": "not found"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/generate":
            self._send(404, {"error": "not found"})
            return
        if not STATE["ready"]:
            self._send(503, {"error": "model still loading"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("text") or "").strip()
            voice = (req.get("voice") or "").strip()
            voice2 = (req.get("voice2") or "").strip() or None
            if not text:
                self._send(400, {"error": "text is required"})
                return
            if voice not in MODEL["voices"]:
                self._send(400, {"error": f"unknown voice {voice!r}"})
                return
            if voice2 is not None and voice2 not in MODEL["voices"]:
                self._send(400, {"error": f"unknown voice2 {voice2!r}"})
                return
            blend = min(100, max(0, int(req.get("blend") or 100)))
            speed = min(1.5, max(0.5, float(req.get("speed") or 1.0)))
            pitch = min(6.0, max(-6.0, float(req.get("pitch") or 0)))
            lang = req.get("lang") if req.get("lang") in ("en-us", "en-gb") else "auto"
            label = re.sub(r"[^A-Za-z0-9_-]", "_", (req.get("label") or "").strip()) or f"kk_{voice}"
            final, i = label, 2
            while os.path.exists(os.path.join(OUT, final + ".m4a")):
                final = f"{label}_{i}"
                i += 1
            with GEN_LOCK:
                STATE["busy"] = True
                try:
                    seconds = synthesize(voice, voice2, blend, text, final, speed, pitch, lang)
                finally:
                    STATE["busy"] = False
            self._send(200, {"file": final + ".m4a", "seconds": seconds})
        except Exception as e:
            STATE["busy"] = False
            self._send(500, {"error": f"{type(e).__name__}: {e}"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    args = ap.parse_args()
    threading.Thread(target=load_model, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Kokoro sampler UI: http://127.0.0.1:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
