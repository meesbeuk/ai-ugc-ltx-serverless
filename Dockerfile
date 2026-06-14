# LTX-2.3 serverless worker — LEAN self-contained image (multi-DC, no volume).
# Official PyTorch+CUDA base (~7GB) + ComfyUI core + only the nodes the LTX i2v graph uses + the
# lean weight set (distilled + gemma, 39GB). ~50GB final. HARDENED so no step can silently hang:
# every heavy op is wrapped in `timeout`, torch is pinned (no resolver churn), wheels-only (no
# surprise compiles), wget has real timeouts+retries. A hang becomes a fast visible failure.
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive COMFY_DIR=/opt/ComfyUI PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 PIP_PREFER_BINARY=1 PIP_DEFAULT_TIMEOUT=60 PIP_PROGRESS_BAR=off

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ffmpeg wget ca-certificates && rm -rf /var/lib/apt/lists/*
RUN pip install runpod

# lock torch/vision/audio to the base's versions so pip never re-resolves/re-downloads torch
# (the main cause of multi-hour resolver backtracking). A real conflict now fails FAST + visibly.
RUN python - > /constraints.txt <<'PY'
import importlib.metadata as m
for p in ("torch","torchvision","torchaudio"):
    try: print(p+"=="+m.version(p))
    except Exception: pass
PY
ENV PIP_CONSTRAINT=/constraints.txt

# ComfyUI core (torch already satisfied by the base + constraint)
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
 && timeout 900 pip install -r /opt/ComfyUI/requirements.txt

# only the nodes the graph needs. wheels-only + per-node timeout so one bad dep can't hang/fail the build.
WORKDIR /opt/ComfyUI/custom_nodes
RUN for url in \
      https://github.com/Lightricks/ComfyUI-LTXVideo \
      https://github.com/ClownsharkBatwing/RES4LYF \
      https://github.com/kijai/ComfyUI-KJNodes \
      https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite ; do \
      d=$(basename "$url"); git clone --depth 1 "$url" "$d"; \
      if [ -f "$d/requirements.txt" ]; then timeout 600 pip install --only-binary=:all: -r "$d/requirements.txt" || timeout 600 pip install -r "$d/requirements.txt" || true; fi; \
    done

# --- weights BAKED IN (separate steps so the log shows which file; hard timeouts, retries, no hf-xet) ---
RUN mkdir -p /opt/ComfyUI/models/checkpoints /opt/ComfyUI/models/text_encoders \
 && timeout 2400 wget --timeout=60 --read-timeout=120 --tries=30 -c -O /opt/ComfyUI/models/checkpoints/ltx-2.3-22b-distilled-fp8.safetensors \
      "https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-distilled-fp8.safetensors?download=true"
RUN timeout 1200 wget --timeout=60 --read-timeout=120 --tries=30 -c -O /opt/ComfyUI/models/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors \
      "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors?download=true" \
 && ls -la /opt/ComfyUI/models/checkpoints /opt/ComfyUI/models/text_encoders

COPY handler.py /workspace/serverless/handler.py
COPY start.sh   /start.sh
RUN chmod +x /start.sh

CMD ["bash", "/start.sh"]
