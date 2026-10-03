#!/usr/bin/env bash
# Fetches the toolchain artifacts and checks their hashes.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lemonseed"
LLVM_VERSION="${LLVM_VERSION:-21.1.0}"

log() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }

fetch() {
  local url="$1" sha="$2" dest="$CACHE/$(basename "$1")"
  if [[ -f "$dest" ]] && echo "$sha  $dest" | shasum -a 256 -c - >/dev/null 2>&1; then
    log "cached $(basename "$dest")"
    return 0
  fi
  mkdir -p "$CACHE"
  curl --fail --location --retry 3 -o "$dest" "$url"
  echo "$sha  $dest" | shasum -a 256 -c -
}

case "${1:-all}" in
  llvm) fetch "https://example.com/llvm-$LLVM_VERSION-ios.tar.zst" "d34db33f" ;;
  all)
    for component in llvm wasi-sysroot; do
      "$0" "$component"
    done
    ;;
  *) echo "usage: $0 [llvm|all]" >&2; exit 64 ;;
esac
