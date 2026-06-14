#!/bin/bash
# Cold-start entrypoint for the DEPS-ONLY LTX serverless worker. ComfyUI + nodes + python deps are
# baked in the IMAGE; the 42GB weight set lives on a mounted network volume and is symlinked into
# ComfyUI/models at boot — fast load, no per-boot install, no dependency drift. RunPod serverless
# mounts the network volume at /runpod-volume (a plain pod mounts it at /workspace).
set -uo pipefail
COMFY=/opt/ComfyUI
export COMFY_DIR=$COMFY
mkdir -p /workspace "$COMFY/models"

# locate the volume's models dir across the layouts we might have provisioned
MODELS=""
for cand in /runpod-volume/ComfyUI/models /runpod-volume/models /workspace/ComfyUI/models /workspace/models; do
  [ -d "$cand" ] && { MODELS="$cand"; break; }
done

{
  echo "[start] $(date -u)  volume models dir = ${MODELS:-NONE FOUND}"
  if [ -n "$MODELS" ]; then
    # symlink every model subfolder's files into the image's ComfyUI/models so the loaders find them
    for sub in "$MODELS"/*/; do
      [ -d "$sub" ] || continue
      name=$(basename "$sub")
      mkdir -p "$COMFY/models/$name"
      for f in "$sub"*; do [ -e "$f" ] && ln -sf "$f" "$COMFY/models/$name/"; done
    done
  else
    echo "[start] WARNING: no volume weights found — render will fail at the model loaders"
  fi
  echo "== checkpoints ==";   ls -laL "$COMFY/models/checkpoints"   2>&1
  echo "== text_encoders =="; ls -laL "$COMFY/models/text_encoders" 2>&1
  echo "== vae ==";           ls -laL "$COMFY/models/vae"           2>&1
} > /workspace/bootstrap.log 2>&1

( cd "$COMFY" && python main.py --listen 127.0.0.1 --port 8188 > /workspace/comfyui.serverless.log 2>&1 & )
echo "[start] ComfyUI launching (weights from volume); exec handler"
exec python -u /workspace/serverless/handler.py
