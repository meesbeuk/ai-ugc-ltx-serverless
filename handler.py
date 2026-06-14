"""RunPod serverless handler for the LTX-2.3 ComfyUI worker.

Per job: receive a ComfyUI API-format `workflow` (+ optional base64 `images`), run it on the local
ComfyUI (launched from the mounted /workspace network volume by start.sh), and return the rendered
clip as base64 (small clips) — or, if you wire S3, a URL.

event["input"] = {
  "workflow": {...},                       # ComfyUI API graph, already mutated by run_serverless.py
  "images":  [{"name": "ref.png", "image": "<base64>"}],   # written to ComfyUI/input for LoadImage
  "output_ext": [".mp4", ".webm"],         # advisory
  "timeout": 1800
}
returns {"video_b64": "...", "filename": "...", "bytes": N}  or  {"error": "..."}.
"""
import os, time, json, base64, subprocess, urllib.request, urllib.parse
import runpod


def _tail(path, n=50):
    try:
        return "".join(open(path, errors="replace").readlines()[-n:])
    except Exception as e:
        return f"(no {path}: {e})"


def _diag():
    try:
        ps = subprocess.run(["bash", "-c", "ps aux | grep -E 'main.py|comfy' | grep -v grep | head -5"],
                            capture_output=True, text=True, timeout=10).stdout
    except Exception as e:
        ps = str(e)
    return {"ps": ps, "comfy_dir": os.path.isdir(COMFY_DIR),
            "main_py": os.path.isfile(os.path.join(COMFY_DIR, "main.py")),
            "which_python": subprocess.run(["bash", "-c", "which python; python -c 'import torch;print(torch.__version__)' 2>&1 | head -1"],
                                           capture_output=True, text=True, timeout=15).stdout}

COMFY = "http://127.0.0.1:8188"
COMFY_DIR = os.environ.get("COMFY_DIR", "/workspace/ComfyUI")
INPUT_DIR = os.path.join(COMFY_DIR, "input")
VIDEO_EXTS = (".mp4", ".webm", ".gif")
MAX_B64_BYTES = int(os.environ.get("MAX_B64_BYTES", 18_000_000))  # guard the response size cap


def _get(path, timeout=30):
    with urllib.request.urlopen(COMFY + path, timeout=timeout) as r:
        return json.loads(r.read())


def _post(path, body, timeout=60):
    req = urllib.request.Request(COMFY + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def wait_comfy(timeout=600):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            _get("/system_stats", timeout=5)
            return True
        except Exception:
            time.sleep(2)
    raise RuntimeError("ComfyUI did not become ready within %ss" % timeout)


def write_images(images):
    os.makedirs(INPUT_DIR, exist_ok=True)
    for im in images or []:
        name = os.path.basename(im["name"])
        open(os.path.join(INPUT_DIR, name), "wb").write(base64.b64decode(im["image"]))


def find_video(outputs):
    """ComfyUI history outputs: node -> {"gifs"/"videos"/"images": [{filename, subfolder, type}]}."""
    for node in (outputs or {}).values():
        for key in ("gifs", "videos", "images"):
            for f in node.get(key, []) or []:
                if f.get("filename", "").lower().endswith(VIDEO_EXTS):
                    return f
    return None


def fetch_view(f):
    q = urllib.parse.urlencode({"filename": f["filename"], "subfolder": f.get("subfolder", ""),
                                "type": f.get("type", "output")})
    with urllib.request.urlopen(COMFY + "/view?" + q, timeout=600) as r:
        return r.read(), f["filename"]


def handler(event):
    inp = event.get("input") or {}
    wf = inp.get("workflow")
    if not wf:
        return {"error": "no workflow in input"}
    try:
        try:
            wait_comfy(int(inp.get("comfy_timeout", 900)))
        except Exception as e:
            return {"error": f"{type(e).__name__}: {e}",
                    "comfy_log": _tail("/workspace/comfyui.serverless.log"),
                    "bootstrap_log": _tail("/workspace/bootstrap.log"),
                    "diag": _diag()}
        write_images(inp.get("images"))
        pid = _post("/prompt", {"prompt": wf}).get("prompt_id")
        if not pid:
            return {"error": "ComfyUI /prompt returned no prompt_id"}
        t0 = time.time()
        timeout = int(inp.get("timeout", 1800))
        hist = None
        while time.time() - t0 < timeout:
            hist = _get(f"/history/{pid}", timeout=30).get(pid)
            if hist and (hist.get("status", {}).get("completed") or hist.get("outputs")):
                break
            time.sleep(3)
        if not hist or not hist.get("outputs"):
            return {"error": f"render timed out after {timeout}s"}
        f = find_video(hist.get("outputs"))
        if not f:
            return {"error": "no video output found", "outputs": str(hist.get("outputs"))[:500]}
        data, fname = fetch_view(f)
        out = {"filename": fname, "bytes": len(data)}
        if len(data) <= MAX_B64_BYTES:
            out["video_b64"] = base64.b64encode(data).decode()
        else:
            out["error"] = (f"video {len(data)}b exceeds MAX_B64_BYTES ({MAX_B64_BYTES}); "
                            "wire S3 output (see worker/README.md)")
        return out
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}


runpod.serverless.start({"handler": handler})
