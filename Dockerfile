# LTX-2.3 serverless worker — FULLY SELF-CONTAINED (deps + WEIGHTS baked in, NO network volume).
# v1 baked only deps and kept weights on a volume, but the volume pinned the endpoint to one DC
# (US-KS-2) whose serverless GPU stock is intermittently dry -> jobs queue forever. v2 bakes the
# lean distilled weight set into the image so the endpoint runs in ANY datacenter with capacity.
# Lean set = distilled checkpoint (27GB) + gemma text encoder (12GB) only. Skipped on purpose:
# dev checkpoint (abandoned), flux (start frames come from gpt-image-2 client-side), upscalers
# (later quality tier). Cold start = pull image -> launch ComfyUI -> handler ready. Zero installs, no mount.
FROM wlsdml1114/engui_genai-base_ada:1.1

# the engui base wires its CUDA/torch python env via login-shell profile scripts, so every build
# step (and the runtime CMD) must run under a LOGIN shell or pip lands in the wrong interpreter.
SHELL ["/bin/bash", "-lc"]
ENV DEBIAN_FRONTEND=noninteractive COMFY_DIR=/opt/ComfyUI PYTHONUNBUFFERED=1

RUN apt-get update -qq && apt-get install -y -qq git ffmpeg wget && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir runpod huggingface_hub

# ComfyUI core
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
 && pip install --no-cache-dir -r /opt/ComfyUI/requirements.txt

# custom nodes (same set provision_ltx.sh installs on the working pod path) + their deps
WORKDIR /opt/ComfyUI/custom_nodes
RUN set -e; for url in \
      https://github.com/Comfy-Org/ComfyUI-Manager \
      https://github.com/Lightricks/ComfyUI-LTXVideo \
      https://github.com/ClownsharkBatwing/RES4LYF \
      https://github.com/kijai/ComfyUI-KJNodes \
      https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite \
      https://github.com/Fannovel16/ComfyUI-Frame-Interpolation ; do \
      git clone --depth 1 "$url" "$(basename "$url")"; \
      [ -f "$(basename "$url")/requirements.txt" ] && pip install --no-cache-dir -r "$(basename "$url")/requirements.txt" || true; \
    done

# --- model weights BAKED IN (lean distilled set; public non-gated repos) ---
# plain wget straight to the final path: no hf-xet (its writer crashed mid-download), no temp-copy
# doubling, follows the HF CDN redirect. -c resumes if a transfer hiccups.
RUN mkdir -p /opt/ComfyUI/models/checkpoints /opt/ComfyUI/models/text_encoders \
 && wget -c -q -O /opt/ComfyUI/models/checkpoints/ltx-2.3-22b-distilled-fp8.safetensors \
      "https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-distilled-fp8.safetensors?download=true" \
 && wget -c -q -O /opt/ComfyUI/models/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors \
      "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors?download=true" \
 && ls -la /opt/ComfyUI/models/checkpoints /opt/ComfyUI/models/text_encoders

COPY handler.py /workspace/serverless/handler.py
COPY start.sh   /start.sh
RUN chmod +x /start.sh

CMD ["/bin/bash", "-lc", "/start.sh"]
