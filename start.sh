#!/bin/bash
# Cold-start entrypoint for the baked LTX serverless worker. NO installs here — everything is in
# the image. Just point the baked ComfyUI at the volume's weights, launch it, exec the handler.
set -uo pipefail
COMFY=/opt/ComfyUI

# weights live on the mounted network volume (US-KS-2). symlink them into the baked ComfyUI so
# CheckpointLoader/etc resolve. Fallback to /workspace (pod-style mount) just in case.
for V in /runpod-volume/ComfyUI/models /workspace/ComfyUI/models; do
  if [ -d "$V" ]; then rm -rf "$COMFY/models" && ln -s "$V" "$COMFY/models" && echo "[start] models -> $V"; break; fi
done

{ echo "MOUNTS:"; ls -la / ; echo "--- runpod-volume:"; ls -la /runpod-volume 2>&1; \
  echo "--- models:"; ls -la "$COMFY/models/checkpoints" 2>&1; } > /workspace/bootstrap.log 2>&1

export COMFY_DIR=$COMFY
( cd "$COMFY" && python main.py --listen 127.0.0.1 --port 8188 > /workspace/comfyui.serverless.log 2>&1 & )
echo "[start] ComfyUI launching; exec handler"
exec python -u /workspace/serverless/handler.py
