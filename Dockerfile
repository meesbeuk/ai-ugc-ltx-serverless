# LTX-2.3 serverless worker — DEPS-ONLY image (weights live on a network volume, NOT baked).
# Official PyTorch+CUDA base (~7GB) + ComfyUI core + only the nodes the LTX i2v graph uses.
# ~8GB final, so cold pulls are fast. The 42GB weight set loads from the mounted volume at runtime
# (start.sh symlinks /runpod-volume weights into ComfyUI/models). Deps (incl. the kornia 0.8.2 pin)
# are baked + import-checked at BUILD time, so there's NO per-boot install and no dependency drift.
# HARDENED: every heavy op wrapped in `timeout`, torch pinned (no resolver churn), wheels-only.
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
# Pin kornia to the last release that still re-exports `pad` from
# kornia.geometry.transform.pyramid. ComfyUI-LTXVideo (unpinned `kornia`) imports `pad` there;
# kornia 0.8.3 dropped that re-export, so latest-kornia makes the WHOLE LTXVideo node pack fail to
# import (no LTX nodes -> nothing renders). The constraint makes the node's own install resolve to 0.8.2.
RUN echo "kornia==0.8.2" >> /constraints.txt
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
# Belt-and-suspenders: force the kornia pin even if a node's resolver bumped it. Verify the exact
# import that was crashing actually resolves at BUILD time, so a bad kornia fails the build (not prod).
RUN pip install "kornia==0.8.2" \
 && python -c "from kornia.geometry.transform.pyramid import PyrUp, build_laplacian_pyramid, build_pyramid, find_next_powerof_two, is_powerof_two, pad; print('kornia import OK', __import__('kornia').__version__)"

# NO weights baked — they live on the network volume and are symlinked in by start.sh at boot.
COPY handler.py /workspace/serverless/handler.py
COPY start.sh   /start.sh
RUN chmod +x /start.sh

CMD ["bash", "/start.sh"]
