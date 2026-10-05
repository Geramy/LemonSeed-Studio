#!/usr/bin/env bash
# Assembles the WASI resources the in-process compiler needs and that ship in
# the app bundle as a folder named "WASIToolchain":
#
#   WASIToolchain/sysroot/          wasi-libc + libc++ for wasm32-wasip1
#                                   (static libraries and headers only)
#   WASIToolchain/clang/            clang resource dir: builtin headers from the
#                                   pinned LLVM source, compiler-rt builtins
#                                   from the pinned wasi-sdk
#
# Output: Toolchain/build/resources/WASIToolchain (gitignored).
#
# Environment:
#   WASI_TARGETS="wasm32-wasip1 wasm32-wasip1-threads"   sysroot targets to keep
#                                   (wasm32-wasip1-threads: pthreads on wasi-threads)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../versions.env
source "$TOOLCHAIN_DIR/versions.env"

BUILD_DIR="$TOOLCHAIN_DIR/build"
DOWNLOADS="$BUILD_DIR/downloads"
OUT="$BUILD_DIR/resources/WASIToolchain"
WASI_TARGETS="${WASI_TARGETS:-wasm32-wasip1 wasm32-wasip1-threads}"
LLVM_MAJOR="${LLVM_VERSION%%.*}"
LLVM_SRC="$BUILD_DIR/src/llvm-project-$LLVM_VERSION.src"

mkdir -p "$DOWNLOADS"

fetch() { # url sha256 dest
  local url="$1" sum="$2" dest="$3"
  if [[ ! -f "$dest" ]]; then
    curl -fL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  echo "$sum  $dest" | shasum -a 256 -c -
}

sysroot_tgz="$DOWNLOADS/wasi-sysroot-$WASI_SDK_FULL_VERSION.tar.gz"
rt_tgz="$DOWNLOADS/libclang_rt-$WASI_SDK_FULL_VERSION.tar.gz"
fetch "$WASI_SYSROOT_URL" "$WASI_SYSROOT_SHA256" "$sysroot_tgz"
fetch "$WASI_RT_URL" "$WASI_RT_SHA256" "$rt_tgz"

if [[ ! -d "$LLVM_SRC/clang/lib/Headers" ]]; then
  echo "LLVM source not found at $LLVM_SRC; run build-llvm-ios.sh fetch first" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$sysroot_tgz" -C "$tmp"
tar -xzf "$rt_tgz" -C "$tmp"
src_sysroot="$tmp/wasi-sysroot-$WASI_SDK_FULL_VERSION"
src_rt="$tmp/libclang_rt-$WASI_SDK_FULL_VERSION"

rm -rf "$OUT"
mkdir -p "$OUT/sysroot/include" "$OUT/sysroot/lib"
cp "$src_sysroot/VERSION" "$OUT/sysroot/VERSION"

for t in $WASI_TARGETS; do
  cp -R "$src_sysroot/include/$t" "$OUT/sysroot/include/$t"
  mkdir -p "$OUT/sysroot/lib/$t"
  # Static libraries and crt objects only: no shared objects, no LTO variants.
  find "$src_sysroot/lib/$t" -maxdepth 1 -type f \( -name '*.a' -o -name '*.o' \) \
    -exec cp {} "$OUT/sysroot/lib/$t/" \;
  rt_dir="$src_rt/wasm32-unknown-${t#wasm32-}"
  mkdir -p "$OUT/clang/lib/wasm32-unknown-${t#wasm32-}"
  cp "$rt_dir/libclang_rt.builtins.a" "$OUT/clang/lib/wasm32-unknown-${t#wasm32-}/"
done

# wasi-sdk ships the same headers for wasm32-wasip1 and wasm32-wasip1-threads
# (the threads difference is in the libraries). Keep one copy: the threads
# target's include directory becomes a link to the plain one (16 MB less in
# the app), but only while every file is identical.
if [[ -d "$OUT/sysroot/include/wasm32-wasip1" && -d "$OUT/sysroot/include/wasm32-wasip1-threads" ]] &&
   diff -rq "$OUT/sysroot/include/wasm32-wasip1" "$OUT/sysroot/include/wasm32-wasip1-threads" >/dev/null; then
  rm -rf "$OUT/sysroot/include/wasm32-wasip1-threads"
  ln -s wasm32-wasip1 "$OUT/sysroot/include/wasm32-wasip1-threads"
fi

# clang finds libc++'s version by listing <sysroot>/include/c++ (it expects
# v1 there) before it adds <sysroot>/include/<target>/c++/v1. Keep that
# directory, with a marker file so bundling never drops it as empty.
mkdir -p "$OUT/sysroot/include/c++/v1"
echo "libc++ headers live in include/<target>/c++/v1" >"$OUT/sysroot/include/c++/v1/README.txt"

# Builtin headers straight from the pinned clang source (the generated
# target-specific headers such as arm_neon.h are not needed for wasm).
mkdir -p "$OUT/clang/include"
cp "$LLVM_SRC"/clang/lib/Headers/*.h "$OUT/clang/include/"
cp "$LLVM_SRC/clang/lib/Headers/module.modulemap" "$OUT/clang/include/"

cat >"$OUT/README.txt" <<EOF
LemonSeed Studio WASI toolchain resources
wasi-sdk $WASI_SDK_FULL_VERSION sysroot ($(head -1 "$src_sysroot/VERSION")), targets: $WASI_TARGETS
clang $LLVM_VERSION builtin headers; compiler-rt builtins from wasi-sdk $WASI_SDK_FULL_VERSION
Use: clang -resource-dir <this>/clang --sysroot=<this>/sysroot --target=wasm32-wasip1
EOF

du -sh "$OUT" "$OUT"/sysroot "$OUT"/clang
