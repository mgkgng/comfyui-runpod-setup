# syntax=docker/dockerfile:1
# =============================================================================
# ComfyUI + custom frontend fork, fully baked for fast RunPod boots.
#
# Everything slow (torch, ComfyUI, the frontend BUILD, custom nodes) happens
# HERE at image-build time. At runtime the pod only launches the server and
# downloads models to the /workspace volume in the background.
#
# Build & push (run on your machine or CI):
#   docker build -t <dockerhub-user>/comfyui-runpod:latest .
#   docker push  <dockerhub-user>/comfyui-runpod:latest
#
# Rebuild whenever you update your frontend fork / node list, then in the
# RunPod template set "Container Image" to your tag and leave the start
# command EMPTY (the image CMD runs start.sh).
# =============================================================================
ARG CUDA_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04
FROM ${CUDA_IMAGE}

# --- what to bake (override with --build-arg KEY=VALUE) ---------------------
ARG COMFYUI_REPO=https://github.com/comfyanonymous/ComfyUI.git
ARG COMFYUI_REF=master
ARG FRONTEND_REPO=https://github.com/mgkgng/ComfyUI_frontend.git
ARG FRONTEND_REF=main
# cu128 wheels run on Ampere -> Blackwell (RTX 3090 ... 5090 / B200)
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
ARG TORCH_PKGS="torch torchvision torchaudio"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    VENV_DIR=/opt/venv \
    COMFYUI_DIR=/opt/ComfyUI \
    FRONTEND_DIR=/opt/ComfyUI_frontend \
    PATH=/opt/venv/bin:$PATH

# --- system deps + Node 20 (only needed to BUILD the frontend) --------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-dev \
        git aria2 wget curl ca-certificates unzip build-essential \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- python venv + torch (cu128 wheels bundle their own CUDA userspace) ------
RUN python3 -m venv "$VENV_DIR" \
    && pip install --upgrade pip wheel setuptools \
    && pip install ${TORCH_PKGS} --index-url ${TORCH_INDEX_URL}

# --- ComfyUI backend + requirements -----------------------------------------
RUN git clone "$COMFYUI_REPO" "$COMFYUI_DIR" \
    && git -C "$COMFYUI_DIR" checkout "$COMFYUI_REF" \
    && pip install -r "$COMFYUI_DIR/requirements.txt" \
    && pip install "huggingface_hub[cli]" hf_transfer

# --- custom frontend fork: clone + build the dist (baked into the image) -----
RUN git clone "$FRONTEND_REPO" "$FRONTEND_DIR" \
    && git -C "$FRONTEND_DIR" checkout "$FRONTEND_REF" \
    && cd "$FRONTEND_DIR" \
    && npm ci \
    && npm run build

# --- custom nodes + their python deps (baked) -------------------------------
COPY custom_nodes.txt /opt/deploy/custom_nodes.txt
RUN set -e; dir="$COMFYUI_DIR/custom_nodes"; mkdir -p "$dir"; \
    while IFS= read -r raw; do \
      repo="$(echo "$raw" | sed 's/#.*//' | xargs)"; [ -z "$repo" ] && continue; \
      name="$(basename "$repo" .git)"; \
      echo "  + $name"; \
      git clone --depth 1 "$repo" "$dir/$name" || { echo "  ! clone failed: $repo"; continue; }; \
      [ -f "$dir/$name/requirements.txt" ] && pip install -r "$dir/$name/requirements.txt" || true; \
    done < /opt/deploy/custom_nodes.txt; \
    true

# --- runtime launcher + model manifest --------------------------------------
COPY start.sh   /opt/deploy/start.sh
COPY models.txt /opt/deploy/models.txt
RUN chmod +x /opt/deploy/start.sh

EXPOSE 8188
CMD ["/opt/deploy/start.sh"]
