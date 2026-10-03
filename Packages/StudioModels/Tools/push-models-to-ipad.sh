#!/usr/bin/env bash
#
# Copy the Mac's model directories into the iPad app's container, as
# Documents/Models/<id>/, for fast iteration without downloading.
#
#   Tools/push-models-to-ipad.sh                 q4 and the converted Q8 draft
#   Tools/push-models-to-ipad.sh q4 dflash2      q4 and the BF16 draft source
#   Tools/push-models-to-ipad.sh --list          show Documents/Models on the iPad
#
# The app picks the directories up on its next launch, or on Rescan in the
# Models screen. They are matched to the catalog by directory name and
# file sizes. "Verify" then checks every file against its pinned SHA-256.
#
# Environment:
#   DEVICE   CoreDevice identifier (default: the iPad Pro 13" M4)
#   BUNDLE   app bundle id (default: com.geramyloveless.LemonSeedStudio)
#   MODELS   the Mac's model directory (default: mac_amdgpu/build/models)
#   DFLASH2_SNAPSHOT  the incoai/Qwen3.8-27B-DFlash2 snapshot in the HF cache
#
# HF cache snapshots are symlinks into blobs/. They are staged as APFS
# clones with links resolved, which costs no space or time, before copying.
set -euo pipefail

: "${DEVICE:=0AFDDB50-F0FD-531C-9AAF-9FBFA68A8D5A}"
: "${BUNDLE:=com.geramyloveless.LemonSeedStudio}"
: "${MODELS:=$HOME/Documents/Development/mac_amdgpu/build/models}"
: "${DFLASH2_SNAPSHOT:=$HOME/.cache/huggingface/hub/models--incoai--Qwen3.8-27B-DFlash2/snapshots/dedf8df68adfb1afeaf7b7480c0a0243108177b4}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/push-models.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

devicectl_files() {
  xcrun devicectl device "$@" --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE"
}

# push <id> <directory>
push() {
  local id="$1" dir="$2"
  echo "==> $id  ($(du -sh "$dir" | cut -f1)) -> Documents/Models/$id"
  devicectl_files copy to --source "$dir" --destination "Documents/Models/$id"
}

# stage <id> <files...>: clone the files (links resolved) into a fresh directory.
stage() {
  local id="$1"; shift
  mkdir -p "$STAGE/$id"
  for f in "$@"; do cp -cL "$f" "$STAGE/$id/" ; done
  echo "$STAGE/$id"
}

if [[ "${1:-}" == "--list" ]]; then
  devicectl_files info files --subdirectory Documents/Models
  exit 0
fi

targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(q4 dflash2-q8)

for t in "${targets[@]}"; do
  case "$t" in
    q4)
      push qwen38-27b-q4 "$(stage qwen38-27b-q4 "$MODELS"/qwen38-27b-q4/{chat_template.jinja,config.json,generation_config.json,model-0000{1,2,3}-of-00003.safetensors,model.safetensors.index.json,tokenizer.json})"
      ;;
    dflash2-q8)
      push qwen38-27b-dflash2-q8 "$(stage qwen38-27b-dflash2-q8 "$MODELS"/qwen38-27b-dflash2-q8/{config.json,model.safetensors,source-repository.json})"
      ;;
    dflash2)
      dir="$(stage qwen38-27b-dflash2 "$DFLASH2_SNAPSHOT"/{config.json,model.safetensors})"
      # Where it came from, for the registry and for LSE's conversion manifest.
      printf '{\n  "repository" : "incoai/Qwen3.8-27B-DFlash2",\n  "revision" : "dedf8df68adfb1afeaf7b7480c0a0243108177b4"\n}' > "$dir/hf-origin.json"
      push qwen38-27b-dflash2 "$dir"
      ;;
    *)
      echo "unknown target '$t' (q4, dflash2-q8, dflash2, --list)" >&2
      exit 2
      ;;
  esac
done

echo "Done. Open Models in the app (or relaunch) and tap Verify."
