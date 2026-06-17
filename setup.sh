#!/usr/bin/env bash
# =============================================================================
# ComfyUI add-ons setup
# -----------------------------------------------------------------------------
# Adds custom nodes (custom_nodes.txt) and downloads models (models.txt) into
# an EXISTING ComfyUI install. It does NOT install torch / ComfyUI / a venv and
# does NOT launch anything. Flux base + its VAE are assumed already present.
#
# Usage:
#   ./setup.sh                      # autodetect ComfyUI dir
#   COMFYUI_DIR=/path/to/ComfyUI ./setup.sh
#   PYTHON=/path/to/venv/bin/python ./setup.sh   # pip target for node deps
# =============================================================================
set -Eeuo pipefail

############################################
# CONFIG  (override via env)
############################################
# python used to install custom-node requirements (use your ComfyUI venv python)
PYTHON="${PYTHON:-python3}"

# --- Tokens for gated / locked downloads ------------------------------------
export HF_TOKEN="${HF_TOKEN:-}"
export CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
export HF_HUB_ENABLE_HF_TRANSFER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log(){ echo -e "\n\033[1;36m[setup]\033[0m $*"; }
die(){ echo -e "\033[1;31m[setup] $*\033[0m" >&2; exit 1; }

pip_install(){ "$PYTHON" -m pip install "$@"; }

############################################
# Locate the existing ComfyUI install
############################################
locate_comfyui(){
  if [ -n "${COMFYUI_DIR:-}" ]; then
    [ -f "$COMFYUI_DIR/main.py" ] || die "COMFYUI_DIR=$COMFYUI_DIR has no main.py"
    return 0
  fi
  local c
  for c in "$PWD" "$PWD/ComfyUI" /workspace/ComfyUI "$HOME/ComfyUI" /ComfyUI; do
    if [ -f "$c/main.py" ] && [ -d "$c/custom_nodes" ]; then
      COMFYUI_DIR="$c"; return 0
    fi
  done
  die "Could not find ComfyUI. Set COMFYUI_DIR=/path/to/ComfyUI and rerun."
}

############################################
# Tooling check (need git + a downloader + unzip)
############################################
ensure_tools(){
  command -v git >/dev/null 2>&1 || die "git not found (install it first)"
  if ! command -v aria2c >/dev/null 2>&1; then
    log "aria2c not found -> falling back to wget (slower for big files)"
    command -v wget >/dev/null 2>&1 || die "neither aria2c nor wget found"
  fi
  command -v unzip >/dev/null 2>&1 || log "unzip not found -> .zip models won't extract"
}

############################################
# Custom nodes
############################################
install_custom_nodes(){
  local list="$SCRIPT_DIR/custom_nodes.txt"
  [ -f "$list" ] || { log "no custom_nodes.txt -> skipping nodes"; return 0; }
  local dir="$COMFYUI_DIR/custom_nodes"
  mkdir -p "$dir"
  log "Syncing custom nodes -> $dir"
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
    [ -f "$dir/$name/requirements.txt" ] && pip_install -q -r "$dir/$name/requirements.txt" || true
  done < "$list"
}

############################################
# Models
############################################
download_models(){
  local list="$SCRIPT_DIR/models.txt"
  [ -f "$list" ] || { log "no models.txt -> skipping models"; return 0; }
  log "Downloading models -> $COMFYUI_DIR/models"
  while IFS='|' read -r subdir url fname; do
    subdir="$(echo "${subdir:-}" | xargs || true)"
    url="$(echo "${url:-}" | xargs || true)"
    fname="$(echo "${fname:-}" | xargs || true)"
    [[ -z "$subdir" || "$subdir" == \#* || -z "$url" ]] && continue
    local dest="$COMFYUI_DIR/models/$subdir"
    mkdir -p "$dest"
    [ -z "$fname" ] && fname="$(basename "${url%%\?*}")"
    if [ -f "$dest/$fname" ]; then echo "  = $subdir/$fname (exists)"; continue; fi
    # archive already extracted on a prior run? (zip is deleted after extract)
    if [[ "$fname" == *.zip ]] && compgen -G "$dest/*.onnx" >/dev/null 2>&1; then
      echo "  = $subdir (extracted, exists)"; continue
    fi
    echo "  + $subdir/$fname"
    local hdr=()
    [[ "$url" == *huggingface.co* && -n "$HF_TOKEN" ]] && hdr=(--header="Authorization: Bearer $HF_TOKEN")
    if [[ "$url" == *civitai.com* && -n "$CIVITAI_TOKEN" ]]; then
      [[ "$url" == *\?* ]] && url="${url}&token=${CIVITAI_TOKEN}" || url="${url}?token=${CIVITAI_TOKEN}"
    fi
    if { command -v aria2c >/dev/null 2>&1 \
           && aria2c -x16 -s16 -k1M --continue=true "${hdr[@]}" -d "$dest" -o "$fname" "$url"; } \
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
  command -v unzip >/dev/null 2>&1 || { echo "  ! unzip missing, left archive: $zip"; return 0; }
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

main(){
  locate_comfyui
  log "Target ComfyUI: $COMFYUI_DIR  (pip via: $PYTHON)"
  ensure_tools
  install_custom_nodes
  download_models
  log "Done. Restart ComfyUI to load new custom nodes."
}
main "$@"
