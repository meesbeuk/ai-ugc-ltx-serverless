# LTX-2.3 serverless worker — LEAN self-contained image (multi-DC, no volume).
# v2 used the engui kitchen-sink base (~30GB) -> ~70GB image that wouldn't build anywhere.
# v3 uses an official PyTorch+CUDA base (~7GB) and installs ONLY what the LTX i2v workflow needs:
# ComfyUI core + ComfyUI-LTXVideo (provides every LTXV*/LTXAV*/LTX2_NAG node in the graph) + a couple
# small python node packs. Frame-Interpolation (cupy, --no-smooth path) and ComfyUI-Manager (UI) are
# dropped. Final image ~50GB (mostly the 39GB weights) -> builds on a normal runner, cold-starts faster.
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive COMFY_DIR=/opt/ComfyUI PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ffmpeg wget ca-certificates build-essential \
 && rm -rf /var/lib/apt/lists/*
RUN pip install runpod

# ComfyUI core (torch already in the base; reqs won't re-pull it)
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
 && pip install -r /opt/ComfyUI/requirements.txt

# custom nodes the graph actually uses (LTXVideo is required; RES4LYF/KJNodes/VHS cover any
# ManualSigmas/NAG/helper classes). per-node deps are best-effort so one optional accel dep can't
# fail the whole build — the node's python still loads (optional accelerators are import-guarded).
WORKDIR /opt/ComfyUI/custom_nodes
RUN for url in \
      https://github.com/Lightricks/ComfyUI-LTXVideo \
      https://github.com/ClownsharkBatwing/RES4LYF \
      https://github.com/kijai/ComfyUI-KJNodes \
      https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite ; do \
      d=$(basename "$url"); git clone --depth 1 "$url" "$d"; \
      if [ -f "$d/requirements.txt" ]; then pip install -r "$d/requirements.txt" || true; fi; \
    done

# --- model weights BAKED IN (lean distilled set; public non-gated repos; plain wget, no hf-xet) ---
RUN mkdir -p /opt/ComfyUI/models/checkpoints /opt/ComfyUI/models/text_encoders \
 && wget -c -q -O /opt/ComfyUI/models/checkpoints/ltx-2.3-22b-distilled-fp8.safetensors \
      "https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-distilled-fp8.safetensors?download=true" \
 && wget -c -q -O /opt/ComfyUI/models/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors \
      "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors?download=true" \
 && ls -la /opt/ComfyUI/models/checkpoints /opt/ComfyUI/models/text_encoders

COPY handler.py /workspace/serverless/handler.py
COPY start.sh   /start.sh
RUN chmod +x /start.sh

CMD ["bash", "/start.sh"]
