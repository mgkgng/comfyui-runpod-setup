#!/usr/bin/env bash
# =============================================================================
# ComfyUI auto-deploy bootstrap for RunPod
# -----------------------------------------------------------------------------
# Everything is installed onto the network volume (/workspace) inside a venv,
# so the FIRST boot provisions and every later boot starts in seconds and runs
# unchanged on ANY GPU you attach (cu128 torch covers Ampere -> Blackwell).
#
# Reachable at:  https://<POD_ID>-8188.proxy.runpod.net
# =============================================================================
set -Eeuo pipefail

############################################
# CONFIG  (override any of these via RunPod template Environment Variables)
############################################
WORKSPACE="${WORKSPACE:-/workspace}"
VENV_DIR="${VENV_DIR:-$WORKSPACE/venv}"

# --- Backend: official ComfyUI, OR point these at your own fork -------------
COMFYUI_REPO="${COMFYUI_REPO:-https://github.com/comfyanonymous/ComfyUI.git}"
COMFYUI_REF="${COMFYUI_REF:-master}"
COMFYUI_DIR="${COMFYUI_DIR:-$WORKSPACE/ComfyUI}"

# --- Frontend fork: set USE_CUSTOM_FRONTEND=true to build & serve your fork --
USE_CUSTOM_FRONTEND="${USE_CUSTOM_FRONTEND:-true}"
FRONTEND_REPO="${FRONTEND_REPO:-https://github.com/mgkgng/ComfyUI_frontend.git}"
FRONTEND_REF="${FRONTEND_REF:-main}"
FRONTEND_DIR="${FRONTEND_DIR:-$WORKSPACE/ComfyUI_frontend}"
FRONTEND_REBUILD="${FRONTEND_REBUILD:-false}"   # set true to force a rebuild

# --- GPU-agnostic torch: cu128 wheels run on RTX 3090 ... 5090 / B200 -------
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
TORCH_PKGS="${TORCH_PKGS:-torch torchvision torchaudio}"

# --- Listen config (do not change unless you also change the exposed port) --
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_EXTRA_ARGS="${COMFY_EXTRA_ARGS:-}"        # e.g. "--fast --use-sage-attention"

# --- Tokens for gated / locked downloads ------------------------------------
export HF_TOKEN="${HF_TOKEN:-}"
export CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
export HF_HUB_ENABLE_HF_TRANSFER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log(){ echo -e "\n\033[1;36m[deploy]\033[0m $*"; }

############################################
# Steps (all idempotent -> safe to run every boot)
############################################

install_system_deps(){
  if ! command -v git >/dev/null 2>&1 || ! command -v aria2c >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    log "Installing system packages (git, aria2, wget, curl, unzip)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends git aria2 wget curl ca-certificates unzip
  fi
}

install_node(){
  command -v node >/dev/null 2>&1 && return 0
  log "Installing Node.js 20 (needed to build the frontend fork)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
}

setup_python(){
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating persistent venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel setuptools >/dev/null
}

install_torch(){
  if python -c "import torch" >/dev/null 2>&1; then
    log "torch already present: $(python -c 'import torch;print(torch.__version__)')"
    return 0
  fi
  log "Installing torch from $TORCH_INDEX_URL"
  pip install $TORCH_PKGS --index-url "$TORCH_INDEX_URL"
}

setup_comfyui(){
  if [ ! -d "$COMFYUI_DIR/.git" ]; then
    log "Cloning ComfyUI ($COMFYUI_REPO @ $COMFYUI_REF)"
    git clone "$COMFYUI_REPO" "$COMFYUI_DIR"
    git -C "$COMFYUI_DIR" checkout "$COMFYUI_REF"
  fi
  log "Installing ComfyUI requirements"
  pip install -r "$COMFYUI_DIR/requirements.txt"
  pip install -q "huggingface_hub[cli]" hf_transfer
}

setup_frontend(){
  [ "$USE_CUSTOM_FRONTEND" = "true" ] || { log "Using bundled frontend"; return 0; }
  install_node
  if [ ! -d "$FRONTEND_DIR/.git" ]; then
    log "Cloning frontend fork ($FRONTEND_REPO @ $FRONTEND_REF)"
    git clone "$FRONTEND_REPO" "$FRONTEND_DIR"
    git -C "$FRONTEND_DIR" checkout "$FRONTEND_REF"
  fi
  if [ ! -d "$FRONTEND_DIR/dist" ] || [ "$FRONTEND_REBUILD" = "true" ]; then
    log "Building frontend fork (npm ci && npm run build)..."
    if ! ( cd "$FRONTEND_DIR" && npm ci && npm run build ); then
      log "Frontend build FAILED -> falling back to bundled frontend"
      USE_CUSTOM_FRONTEND=false
    fi
  fi
}

install_custom_nodes(){
  local list="$SCRIPT_DIR/custom_nodes.txt"
  [ -f "$list" ] || return 0
  local dir="$COMFYUI_DIR/custom_nodes"
  mkdir -p "$dir"
  log "Syncing custom nodes"
  while IFS= read -r raw; do
    local repo; repo="$(echo "$raw" | sed 's/#.*//' | xargs || true)"
    [ -z "$repo" ] && continue
    local name; name="$(basename "$repo" .git)"
    if [ ! -d "$dir/$name" ]; then
      echo "  + $name"
      git clone --depth 1 "$repo" "$dir/$name" || { echo "  ! clone failed: $repo"; continue; }
    else
      echo "  = $name (exists)"
    fi
    [ -f "$dir/$name/requirements.txt" ] && pip install -q -r "$dir/$name/requirements.txt" || true
  done < "$list"
}

download_models(){
  local list="$SCRIPT_DIR/models.txt"
  [ -f "$list" ] || return 0
  log "Downloading models"
  while IFS='|' read -r subdir url fname; do
    subdir="$(echo "${subdir:-}" | xargs || true)"
    url="$(echo "${url:-}" | xargs || true)"
    fname="$(echo "${fname:-}" | xargs || true)"
    [[ -z "$subdir" || "$subdir" == \#* || -z "$url" ]] && continue
    local dest="$COMFYUI_DIR/models/$subdir"
    mkdir -p "$dest"
    [ -z "$fname" ] && fname="$(basename "${url%%\?*}")"
    if [ -f "$dest/$fname" ]; then echo "  = $subdir/$fname (exists)"; continue; fi
    # archive already extracted on a prior boot? (zip is deleted after extract)
    if [[ "$fname" == *.zip ]] && compgen -G "$dest/*.onnx" >/dev/null 2>&1; then
      echo "  = $subdir (extracted, exists)"; continue
    fi
    echo "  + $subdir/$fname"
    local hdr=()
    [[ "$url" == *huggingface.co* && -n "$HF_TOKEN" ]] && hdr=(--header="Authorization: Bearer $HF_TOKEN")
    if [[ "$url" == *civitai.com* && -n "$CIVITAI_TOKEN" ]]; then
      [[ "$url" == *\?* ]] && url="${url}&token=${CIVITAI_TOKEN}" || url="${url}?token=${CIVITAI_TOKEN}"
    fi
    if aria2c -x16 -s16 -k1M --continue=true "${hdr[@]}" -d "$dest" -o "$fname" "$url" \
      || wget -q --show-progress "${hdr[@]/--header=/--header=}" -O "$dest/$fname" "$url"; then
      [[ "$fname" == *.zip ]] && extract_flatten "$dest" "$fname"
    else
      echo "  ! download failed (skipped): $subdir/$fname"
    fi
  done < "$list"
  verify_models
}

# Unzip an archive into $dir, then lift model files out of any nested
# folders so they sit directly in $dir (fixes antelopev2/antelopev2/*.onnx).
extract_flatten(){
  local dir="$1" zip="$2"
  echo "  ~ extracting $zip"
  ( cd "$dir" && unzip -oq "$zip" && rm -f "$zip" ) || { echo "  ! unzip failed: $zip"; return 0; }
  # move any model files found below the top level up to $dir (portable mv)
  find "$dir" -mindepth 2 -type f \
    \( -name '*.onnx' -o -name '*.bin' -o -name '*.param' -o -name '*.safetensors' -o -name '*.pt' \) \
    -exec mv -f {} "$dir"/ \; 2>/dev/null || true
  # prune now-empty nested dirs
  find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# Print what actually landed so a failed/gated download is obvious in logs.
verify_models(){
  log "Model inventory ($COMFYUI_DIR/models):"
  local d
  for d in diffusion_models text_encoders vae clip_vision style_models pulid loras \
           insightface/models/antelopev2; do
    local p="$COMFYUI_DIR/models/$d"
    if compgen -G "$p/*" >/dev/null 2>&1; then
      echo "  [ok] $d/"
      ( cd "$p" && ls -1 ) | sed 's/^/        /'
    else
      echo "  [--] $d/  (empty)"
    fi
  done
}

launch(){
  local args=(--listen "$COMFY_HOST" --port "$COMFY_PORT")
  if [ "$USE_CUSTOM_FRONTEND" = "true" ]; then
    args+=(--front-end-root "$FRONTEND_DIR/dist")
  fi
  log "Starting ComfyUI on ${COMFY_HOST}:${COMFY_PORT}"
  echo    "  ===================================================================="
  echo -e "  Open:  \033[1;32mhttps://${RUNPOD_POD_ID:-<POD_ID>}-${COMFY_PORT}.proxy.runpod.net\033[0m"
  echo    "  ===================================================================="
  cd "$COMFYUI_DIR"
  # shellcheck disable=SC2086
  exec python main.py "${args[@]}" $COMFY_EXTRA_ARGS
}

main(){
  mkdir -p "$WORKSPACE"
  install_system_deps
  setup_python
  install_torch
  setup_comfyui
  setup_frontend
  install_custom_nodes
  download_models
  launch
}
main "$@"
