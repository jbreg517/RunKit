"""Local web UI for Kokoro voice sampling — named voices with reliable accents
(bf_*/bm_* British, af_*/am_* American). Much faster than Parler on CPU and
deterministic (no seed). Stdlib HTTP only.

    python kokoro_server.py [--port 8766]

Needs kokoro-v1.0.onnx + voices-v1.0.bin next to this script (see README).
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
        names = sorted(np.load(os.path.join(HERE, "voices-v1.0.bin")).files)
        MODEL["voices"] = [n for n in names if n[:1] in "ab"]
        STATE["ready"] = True
    except Exception as e:
        STATE["error"] = f"{type(e).__name__}: {e}"


def synthesize(voice, text, label, speed):
    import numpy as np, soundfile as sf, imageio_ffmpeg
    lang = "en-gb" if voice.startswith("b") else "en-us"
    samples, sr = MODEL["kokoro"].create(text, voice=voice, speed=speed, lang=lang)
    a = np.asarray(samples, dtype=np.float32).flatten()
    a = a / (float(np.max(np.abs(a))) or 1.0) * 0.89
    wav = os.path.join(tempfile.gettempdir(), "rk_kui.wav")
    sf.write(wav, a, sr)
    path = os.path.join(OUT, label + ".m4a")
    ff = imageio_ffmpeg.get_ffmpeg_exe()
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
  .row { display: flex; gap: 10px; } .row > div { flex: 1; }
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

<label>Voice (accent is built into the voice)</label>
<select id="voice"></select>
<label>Line to speak</label>
<input id="text" placeholder="Nice work! You're flying!" value="Nice work! You're flying!">
<div class="row">
  <div><label>Label (file name)</label><input id="label" placeholder="take1"></div>
  <div><label>Speed (0.7 slow &ndash; 1.3 fast)</label><input id="speed" type="number" step="0.05" min="0.5" max="1.5" value="1.0"></div>
</div>
<button id="go" onclick="generate()" disabled>Generate</button>

<h2>Clips in out/try/ (newest first)</h2>
<div id="clips"></div>

<script>
async function poll() {
  try {
    const s = await (await fetch('/api/status')).json();
    const st = document.getElementById('status');
    if (s.error) { st.innerHTML = '<span class="err">Model failed to load: ' + s.error + '</span>'; return; }
    if (!s.ready) { st.textContent = 'Loading model…'; setTimeout(poll, 1500); return; }
    if (s.voices && !document.getElementById('voice').options.length) {
      const sel = document.getElementById('voice');
      s.voices.forEach(v => { const o = document.createElement('option'); o.value = v.name; o.textContent = v.label; sel.appendChild(o); });
      sel.value = 'bf_emma';
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
    text: document.getElementById('text').value.trim(),
    label: document.getElementById('label').value.trim(),
    speed: parseFloat(document.getElementById('speed').value) || 1.0
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
            if not text:
                self._send(400, {"error": "text is required"})
                return
            if voice not in MODEL["voices"]:
                self._send(400, {"error": f"unknown voice {voice!r}"})
                return
            speed = min(1.5, max(0.5, float(req.get("speed") or 1.0)))
            label = re.sub(r"[^A-Za-z0-9_-]", "_", (req.get("label") or "").strip()) or f"kk_{voice}"
            final, i = label, 2
            while os.path.exists(os.path.join(OUT, final + ".m4a")):
                final = f"{label}_{i}"
                i += 1
            with GEN_LOCK:
                STATE["busy"] = True
                try:
                    seconds = synthesize(voice, text, final, speed)
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
