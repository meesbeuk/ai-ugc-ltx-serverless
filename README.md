# ai-ugc-ltx-serverless

Baked ComfyUI + LTX-2.3 worker image for RunPod serverless. Deps + custom nodes are installed at
build time (NOT on cold start — that was the bug). Model weights stay on the US-KS-2 network volume
and are symlinked in at boot. Image is built by GitHub Actions and pushed to ghcr.

Endpoint: `ltx-serverless-ksv2` (5yf93m9jne5cjr) · volume `od9wl2j8qi` (US-KS-2).
