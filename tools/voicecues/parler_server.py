"""Local web UI for Parler voice sampling. Stdlib HTTP server only — no extra deps.

    python parler_server.py [--port 8765]

Loads the model once (in the background; the page shows status), then each
Generate writes out/try/<label>.m4a — same location as parler_try.py — and the
clip is playable right in the page. Localhost only; nothing leaves the machine.
"""
import argparse, json, os, re, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "try")
os.makedirs(OUT, exist_ok=True)

STATE = {"ready": False, "error": None, "busy": False}
MODEL = {}
GEN_LOCK = threading.Lock()

DEFAULT_DESC = ("A female speaker with a British accent speaks in an excited, upbeat and "
                "encouraging tone at a slightly fast pace. Very clear, high-quality, close-up recording.")

PRESETS = {
    "British female — excited": DEFAULT_DESC,
    "British male — motivating": "A male speaker with a British accent speaks in an enthusiastic, motivating tone at a moderate pace. Very clear, high-quality audio.",
    "American female — cheerful coach": "A female speaker with an American accent speaks cheerfully and energetically, like an upbeat fitness coach. Very clear, high-quality audio.",
    "American male — hype": "A male speaker with an American accent speaks in an energetic, hyped, motivational tone at a fast pace. Very clear audio.",
    "Australian female — warm": "A female speaker with an Australian accent speaks in a warm, upbeat and encouraging tone. Very clear, high-quality audio.",
    "British female — calm": "A female speaker with a British accent speaks in a warm, calm, gently encouraging tone at a measured pace. Very clear, high-quality audio.",
}


def load_model():
    try:
        from parler_tts import ParlerTTSForConditionalGeneration
        from transformers import AutoTokenizer
        repo = "parler-tts/parler-tts-mini-v1"
        model = ParlerTTSForConditionalGeneration.from_pretrained(repo).to("cpu")
        tok = AutoTokenizer.from_pretrained(repo)
        MODEL.update(model=model, tok=tok, sr=model.config.sampling_rate)
        STATE["ready"] = True
    except Exception as e:  # surfaced via /api/status
        STATE["error"] = f"{type(e).__name__}: {e}"


def synthesize(desc, text, label, seed):
    import numpy as np, soundfile as sf, imageio_ffmpeg, torch
    from transformers import set_seed
    if seed is not None:
        set_seed(int(seed))
    tok, model, sr = MODEL["tok"], MODEL["model"], MODEL["sr"]
    ids = tok(desc, return_tensors="pt").input_ids
    pids = tok(text, return_tensors="pt").input_ids
    with torch.no_grad():
        gen = model.generate(input_ids=ids, prompt_input_ids=pids)
    a = gen.cpu().numpy().squeeze().astype(np.float32)
    a = a / (float(np.max(np.abs(a))) or 1.0) * 0.89
    wav = os.path.join(tempfile.gettempdir(), "rk_ui.wav")
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
<title>RunKit Parler sampler</title>
<style>
  :root { color-scheme: dark; }
  body { font-family: -apple-system, "Segoe UI", sans-serif; background:#111; color:#eee;
         max-width: 720px; margin: 0 auto; padding: 16px; }
  h1 { font-size: 1.2em; color: #d4a843; }
  label { display:block; margin: 10px 0 4px; font-size: .85em; color:#aaa; }
  input, textarea, select { width: 100%; box-sizing: border-box; background:#1c1c1e; color:#eee;
         border: 1px solid #333; border-radius: 8px; padding: 8px; font-size: .95em; }
  textarea { min-height: 64px; resize: vertical; }
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
<h1>RunKit &mdash; Parler voice sampler</h1>
<div id="status">Checking model status&hellip;</div>

<label>Voice preset</label>
<select id="preset" onchange="applyPreset()"></select>
<label>Description (the voice: gender, accent, emotion, pace)</label>
<textarea id="desc"></textarea>
<label>Line to speak</label>
<input id="text" placeholder="Nice work! You're flying!" value="Nice work! You're flying!">
<div class="row">
  <div><label>Label (file name)</label><input id="label" placeholder="take1"></div>
  <div><label>Seed (optional, repeatable take)</label><input id="seed" placeholder="random"></div>
</div>
<button id="go" onclick="generate()" disabled>Generate</button>

<h2>Clips in out/try/ (newest first)</h2>
<div id="clips"></div>

<script>
const presets = __PRESETS__;
const sel = document.getElementById('preset');
Object.keys(presets).forEach(k => { const o = document.createElement('option'); o.textContent = k; sel.appendChild(o); });
const custom = document.createElement('option'); custom.textContent = 'Custom'; sel.appendChild(custom);
function applyPreset() { if (sel.value !== 'Custom') document.getElementById('desc').value = presets[sel.value]; }
applyPreset();

let timer = null;
async function poll() {
  try {
    const s = await (await fetch('/api/status')).json();
    const st = document.getElementById('status');
    if (s.error) { st.innerHTML = '<span class="err">Model failed to load: ' + s.error + '</span>'; return; }
    if (!s.ready) { st.textContent = 'Loading model (about a minute)…'; setTimeout(poll, 2000); return; }
    document.getElementById('go').disabled = s.busy;
    st.textContent = s.busy ? 'Generating… (30–90s on CPU)' : 'Ready.';
    if (s.busy) setTimeout(poll, 2000);
  } catch (e) { setTimeout(poll, 2000); }
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
    desc: document.getElementById('desc').value.trim(),
    text: document.getElementById('text').value.trim(),
    label: document.getElementById('label').value.trim(),
    seed: document.getElementById('seed').value.trim()
  };
  if (!body.text) { alert('Enter a line to speak.'); return; }
  document.getElementById('go').disabled = true;
  document.getElementById('status').textContent = 'Generating… (30–90s on CPU)';
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
    def log_message(self, fmt, *args):  # keep stdout clean
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
            html = PAGE.replace("__PRESETS__", json.dumps(PRESETS))
            self._send(200, html.encode(), "text/html; charset=utf-8")
        elif self.path == "/api/status":
            self._send(200, STATE)
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
            if not text:
                self._send(400, {"error": "text is required"})
                return
            desc = (req.get("desc") or "").strip() or DEFAULT_DESC
            label = re.sub(r"[^A-Za-z0-9_-]", "_", (req.get("label") or "").strip()) or "take"
            # avoid silently overwriting an existing clip
            final, i = label, 2
            while os.path.exists(os.path.join(OUT, final + ".m4a")):
                final = f"{label}_{i}"
                i += 1
            seed_raw = str(req.get("seed") or "").strip()
            seed = int(seed_raw) if re.fullmatch(r"-?\d+", seed_raw) else None
            with GEN_LOCK:
                STATE["busy"] = True
                try:
                    seconds = synthesize(desc, text, final, seed)
                finally:
                    STATE["busy"] = False
            self._send(200, {"file": final + ".m4a", "seconds": seconds})
        except Exception as e:
            STATE["busy"] = False
            self._send(500, {"error": f"{type(e).__name__}: {e}"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    threading.Thread(target=load_model, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Parler sampler UI: http://127.0.0.1:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
