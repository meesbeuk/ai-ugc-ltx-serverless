# LTX-2.3 serverless worker — DEPS BAKED IN (no install-on-cold-start).
# Root cause of the old volume-bootstrap failures: the start command pip-installed ComfyUI +
# every custom node on every cold start, so the worker burned GPU for minutes before the handler
# could take a job (often timing out). Here ComfyUI + all node deps are installed at BUILD time;
# the 39GB model weights stay on the US-KS-2 network volume (mounted at /runpod-volume) and are
# symlinked in at boot. Cold start = pull cached image -> launch ComfyUI -> handler ready. No installs.
FROM wlsdml1114/engui_genai-base_ada:1.1

# the engui base wires its CUDA/torch python env via login-shell profile scripts, so every build
# step (and the runtime CMD) must run under a LOGIN shell or pip lands in the wrong interpreter.
SHELL ["/bin/bash", "-lc"]
ENV DEBIAN_FRONTEND=noninteractive HF_HUB_ENABLE_HF_TRANSFER=1 COMFY_DIR=/opt/ComfyUI PYTHONUNBUFFERED=1

RUN apt-get update -qq && apt-get install -y -qq git ffmpeg wget && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir runpod "huggingface_hub[hf_transfer]"

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

COPY handler.py /workspace/serverless/handler.py
COPY start.sh   /start.sh
RUN chmod +x /start.sh

CMD ["/bin/bash", "-lc", "/start.sh"]
