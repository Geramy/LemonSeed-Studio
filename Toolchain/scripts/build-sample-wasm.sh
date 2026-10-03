#!/usr/bin/env bash
# Compiles samples/hello.c to wasm on the Mac with a host clang 21 and the
# bundled WASI resources. The demo app falls back to this module when it is
# built without the in-process LLVM, so the run side can be tested on its own.
#
# Host compiler: $HOST_CLANG, or Homebrew's llvm@21 (+ lld@21 for wasm-ld).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
R="$TOOLCHAIN_DIR/build/resources/WASIToolchain"
OUT="$TOOLCHAIN_DIR/build/resources/prebuilt"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
HOST_CLANG="${HOST_CLANG:-$BREW/opt/llvm@21/bin/clang}"
export PATH="$BREW/opt/lld@21/bin:$PATH"

[[ -d "$R" ]] || { echo "run fetch-wasi-sysroot.sh first" >&2; exit 1; }
mkdir -p "$OUT"
"$HOST_CLANG" --target=wasm32-wasip1 -resource-dir "$R/clang" --sysroot="$R/sysroot" \
  -std=gnu17 -O2 "$TOOLCHAIN_DIR/samples/hello.c" -o "$OUT/hello.wasm"
ls -l "$OUT/hello.wasm"
