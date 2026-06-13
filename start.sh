#!/usr/bin/env bash
# =============================================================================
# ComfyUI runtime launcher (for the image-baked build — see Dockerfile).
# -----------------------------------------------------------------------------
# torch / ComfyUI / the frontend dist / custom nodes are ALREADY in the image.
# This script only:
#   1. points ComfyUI's data dirs (models, output, input, user) at the
#      /workspace volume so they persist across pod recreation,
#   2. starts model downloads in the BACKGROUND (models load on-demand at
#      workflow run, NOT at startup), and
#   3. launches the server immediately.
#
# Reachable at:  https://<POD_ID>-8188.proxy.runpod.net
# =============================================================================
set -Eeuo pipefail

############################################
# CONFIG  (override via RunPod template Environment Variables)
############################################
WORKSPACE="${WORKSPACE:-/workspace}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
FRONTEND_DIR="${FRONTEND_DIR:-/opt/ComfyUI_frontend}"

# All mutable data lives on the volume (survives pod recreation, keeps image slim)
DATA_DIR="${DATA_DIR:-$WORKSPACE}"
MODELS_ROOT="${MODELS_ROOT:-$DATA_DIR/models}"

USE_CUSTOM_FRONTEND="${USE_CUSTOM_FRONTEND:-true}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_EXTRA_ARGS="${COMFY_EXTRA_ARGS:-}"        # e.g. "--fast --use-sage-attention"

# Set true to wait for all model downloads BEFORE launching (default: background)
BLOCK_ON_MODELS="${BLOCK_ON_MODELS:-false}"

# --- Tokens for gated / locked downloads ------------------------------------
export HF_TOKEN="${HF_TOKEN:-}"
export CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
export HF_HUB_ENABLE_HF_TRANSFER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log(){ echo -e "\n\033[1;36m[run]\033[0m $*"; }

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

############################################
# Steps
############################################

prepare_storage(){
  log "Preparing data dirs on volume ($DATA_DIR)"
  mkdir -p "$MODELS_ROOT" "$DATA_DIR/output" "$DATA_DIR/input" "$DATA_DIR/user"
}

download_models(){
  local list="$SCRIPT_DIR/models.txt"
  [ -f "$list" ] || return 0
  log "Downloading models -> $MODELS_ROOT (background)"
  while IFS='|' read -r subdir url fname; do
    subdir="$(echo "${subdir:-}" | xargs || true)"
    url="$(echo "${url:-}" | xargs || true)"
    fname="$(echo "${fname:-}" | xargs || true)"
    [[ -z "$subdir" || "$subdir" == \#* || -z "$url" ]] && continue
    local dest="$MODELS_ROOT/$subdir"
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
  log "Model inventory ($MODELS_ROOT):"
  local d
  for d in diffusion_models text_encoders vae clip_vision style_models pulid loras \
           insightface/models/antelopev2; do
    local p="$MODELS_ROOT/$d"
    if compgen -G "$p/*" >/dev/null 2>&1; then
      echo "  [ok] $d/"
      ( cd "$p" && ls -1 ) | sed 's/^/        /'
    else
      echo "  [--] $d/  (empty)"
    fi
  done
}

launch(){
  # --base-directory points models/output/input/user at the volume.
  local args=(--listen "$COMFY_HOST" --port "$COMFY_PORT" --base-directory "$DATA_DIR")
  if [ "$USE_CUSTOM_FRONTEND" = "true" ] && [ -d "$FRONTEND_DIR/dist" ]; then
    args+=(--front-end-root "$FRONTEND_DIR/dist")
  else
    log "Custom frontend dist missing -> using bundled frontend"
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
  prepare_storage
  if [ "$BLOCK_ON_MODELS" = "true" ]; then
    download_models
  else
    # background: UI is usable immediately; models stream in while you work.
    download_models &
  fi
  launch
}
main "$@"
