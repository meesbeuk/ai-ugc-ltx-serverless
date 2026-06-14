#!/bin/bash
# Cold-start entrypoint for the SELF-CONTAINED LTX serverless worker. Everything (deps, nodes,
# weights) is baked into the image — no network volume, no installs. Just launch ComfyUI + handler.
set -uo pipefail
COMFY=/opt/ComfyUI
export COMFY_DIR=$COMFY

{ echo "models/checkpoints:"; ls -la "$COMFY/models/checkpoints" 2>&1; \
  echo "models/text_encoders:"; ls -la "$COMFY/models/text_encoders" 2>&1; } > /workspace/bootstrap.log 2>&1

( cd "$COMFY" && python main.py --listen 127.0.0.1 --port 8188 > /workspace/comfyui.serverless.log 2>&1 & )
echo "[start] ComfyUI launching (weights baked); exec handler"
exec python -u /workspace/serverless/handler.py
