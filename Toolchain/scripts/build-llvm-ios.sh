#!/usr/bin/env bash
# Builds the pinned LLVM (clang, lld, optionally clangd) as static libraries for
# iOS device arm64 and iOS simulator arm64, and packages them as
# Toolchain/build/xcframeworks/LemonSeedLLVM.xcframework.
#
# Usage: build-llvm-ios.sh [step...]
#   steps: fetch host sim device package   (default: all of them, in order)
#
# Environment:
#   JOBS=10             parallel compile jobs (shared machine: keep it modest)
#   WITH_CLANGD=1       also build clang-tools-extra libraries (clangd, clang-tidy)
#   LLVM_TARGETS=WebAssembly   LLVM backends to build (e.g. "WebAssembly;AMDGPU")
#   BUILD_TYPE=Release
#
# Everything lands in Toolchain/build (gitignored). Each step logs to
# Toolchain/build/logs/<step>.log and appends its wall time to timings.txt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../versions.env
source "$TOOLCHAIN_DIR/versions.env"

BUILD_DIR="$TOOLCHAIN_DIR/build"
DOWNLOADS="$BUILD_DIR/downloads"
SRC_DIR="$BUILD_DIR/src/llvm-project-$LLVM_VERSION.src"
LOG_DIR="$BUILD_DIR/logs"
HOST_DIR="$BUILD_DIR/llvm-host-tools"
OUT_DIR="$BUILD_DIR/xcframeworks"

JOBS="${JOBS:-10}"
WITH_CLANGD="${WITH_CLANGD:-1}"
LLVM_TARGETS="${LLVM_TARGETS:-WebAssembly}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

PROJECTS="clang;lld"
if [[ "$WITH_CLANGD" == 1 ]]; then PROJECTS="clang;clang-tools-extra;lld"; fi

mkdir -p "$DOWNLOADS" "$LOG_DIR" "$OUT_DIR"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

timed() {
  local name="$1"; shift
  local start end
  start=$(date +%s)
  log "begin $name (log: $LOG_DIR/$name.log)"
  # Run the step in a background subshell and wait for it: errexit stays in
  # force inside it (bash ignores set -e in anything called from a condition).
  ( "$@" ) >"$LOG_DIR/$name.log" 2>&1 &
  if ! wait $!; then
    log "FAILED $name; last lines of the log:"
    tail -40 "$LOG_DIR/$name.log"
    exit 1
  fi
  end=$(date +%s)
  printf '%s\t%ss\t%s\n' "$name" "$((end - start))" "$(date '+%Y-%m-%d %H:%M')" >>"$LOG_DIR/timings.txt"
  log "end $name ($((end - start)) s)"
}

ccache_flags() {
  if command -v ccache >/dev/null 2>&1; then
    echo "-DLLVM_CCACHE_BUILD=ON"
  fi
}

# --- fetch -----------------------------------------------------------------

do_fetch() {
  local tarball="$DOWNLOADS/llvm-project-$LLVM_VERSION.src.tar.xz"
  if [[ ! -f "$tarball" ]]; then
    curl -fL --retry 3 -o "$tarball.part" "$LLVM_URL"
    mv "$tarball.part" "$tarball"
  fi
  echo "$LLVM_SHA256  $tarball" | shasum -a 256 -c -
  if [[ ! -d "$SRC_DIR" ]]; then
    mkdir -p "$BUILD_DIR/src"
    tar -xf "$tarball" -C "$BUILD_DIR/src"
    apply_patches
  fi
}

apply_patches() {
  local patch_dir="$TOOLCHAIN_DIR/patches/llvm"
  [[ -d "$patch_dir" ]] || return 0
  local p
  for p in "$patch_dir"/*.patch; do
    [[ -f "$p" ]] || continue
    echo "applying $(basename "$p")"
    patch -d "$SRC_DIR" -p1 --forward <"$p"
  done
}

# --- host tools (tablegen and friends, run on the Mac during the iOS build) --

host_tools() {
  local tools=(llvm-tblgen llvm-min-tblgen clang-tblgen)
  if [[ "$WITH_CLANGD" == 1 ]]; then tools+=(clang-tidy-confusable-chars-gen); fi
  echo "${tools[@]}"
}

do_host() {
  cmake -G Ninja -S "$SRC_DIR/llvm" -B "$HOST_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="$PROJECTS" \
    -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    $(ccache_flags)
  # shellcheck disable=SC2046
  ninja -C "$HOST_DIR" -j "$JOBS" $(host_tools)
}

# --- iOS slices --------------------------------------------------------------

# $1: sim | device
do_ios() {
  local slice="$1" sdk host_triple
  case "$slice" in
    sim)    sdk=iphonesimulator; host_triple=arm64-apple-ios-simulator ;;
    device) sdk=iphoneos;        host_triple=arm64-apple-ios ;;
    *) echo "unknown slice $slice" >&2; return 1 ;;
  esac
  local bdir="$BUILD_DIR/llvm-ios-$slice"
  local idir="$BUILD_DIR/llvm-install-$slice"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  local clangd_flags=()
  if [[ "$WITH_CLANGD" == 1 ]]; then
    clangd_flags=(
      -DCLANGD_BUILD_XPC=OFF
      -DCLANGD_ENABLE_REMOTE=OFF
      -DCLANG_TOOLS_EXTRA_INCLUDE_DOCS=OFF
    )
  fi

  cmake -G Ninja -S "$SRC_DIR/llvm" -B "$bdir" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$idir" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DLLVM_HOST_TRIPLE="$host_triple" \
    -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasip1 \
    -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
    -DLLVM_ENABLE_PROJECTS="$PROJECTS" \
    -DLLVM_NATIVE_TOOL_DIR="$HOST_DIR/bin" \
    -DLLVM_TABLEGEN="$HOST_DIR/bin/llvm-tblgen" \
    -DCLANG_TABLEGEN="$HOST_DIR/bin/clang-tblgen" \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DCLANG_BUILD_TOOLS=OFF \
    -DLLD_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_PLUGINS=OFF -DCLANG_PLUGIN_SUPPORT=OFF \
    -DLLVM_ENABLE_CRASH_OVERRIDES=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_ENABLE_OBJC_REWRITER=OFF \
    -DCLANG_TOOL_LIBCLANG_BUILD=OFF \
    -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_PARALLEL_COMPILE_JOBS="$JOBS" \
    "${clangd_flags[@]}" \
    $(ccache_flags)

  ninja -C "$bdir" -j "$JOBS"
  stage_install "$bdir" "$idir"
}

# LLVM's own install target insists on tools we do not build (iOS has no use
# for them), so install by hand: every static library, the public headers of
# llvm, clang and lld (source and generated), clang's resource headers and,
# with clangd, the clang-tools-extra headers an in-process clangd host needs.
stage_install() {
  local bdir="$1" idir="$2"
  rm -rf "$idir"
  mkdir -p "$idir/lib" "$idir/include"
  cp "$bdir"/lib/*.a "$idir/lib/"
  local headers=(--include='*/' --include='*.h' --include='*.def' --include='*.inc'
                 --include='*.gen' --exclude='*')
  local d
  for d in "$SRC_DIR/llvm/include" "$bdir/include" \
           "$SRC_DIR/clang/include" "$bdir/tools/clang/include" \
           "$SRC_DIR/lld/include" "$bdir/tools/lld/include"; do
    [[ -d "$d" ]] && rsync -a -m "${headers[@]}" "$d/" "$idir/include/"
  done
  if [[ "$WITH_CLANGD" == 1 ]]; then
    # Included as <clangd/...> style paths via -I .../clang-tools-extra and
    # -I .../clang-tools-extra/clangd (clangd uses both forms).
    rsync -a -m "${headers[@]}" "$SRC_DIR/clang-tools-extra/" "$idir/include/clang-tools-extra/"
    rsync -a -m "${headers[@]}" "$bdir/tools/clang/tools/extra/" "$idir/include/clang-tools-extra/"
  fi
  cp -R "$bdir/lib/clang" "$idir/lib/clang"
}

# --- package -----------------------------------------------------------------

# Merges every static library of a slice into one archive next to its headers.
stage_slice() {
  local slice="$1"
  local idir="$BUILD_DIR/llvm-install-$slice"
  local sdir="$BUILD_DIR/llvm-stage-$slice"
  rm -rf "$sdir"
  mkdir -p "$sdir/Headers"
  libtool -static -no_warning_for_no_symbols \
    -o "$sdir/libLemonSeedLLVM.a" "$idir"/lib/*.a
  cp -R "$idir/include/." "$sdir/Headers/"
}

do_package() {
  local args=()
  local slice
  for slice in device sim; do
    if [[ -d "$BUILD_DIR/llvm-install-$slice/lib" ]]; then
      stage_slice "$slice"
      args+=(-library "$BUILD_DIR/llvm-stage-$slice/libLemonSeedLLVM.a"
             -headers "$BUILD_DIR/llvm-stage-$slice/Headers")
    else
      echo "warning: slice $slice not built; packaging without it"
    fi
  done
  [[ ${#args[@]} -gt 0 ]] || { echo "nothing to package" >&2; return 1; }
  rm -rf "$OUT_DIR/LemonSeedLLVM.xcframework"
  xcodebuild -create-xcframework "${args[@]}" \
    -output "$OUT_DIR/LemonSeedLLVM.xcframework"

  # clang's builtin headers (stddef.h, stdarg.h, ...) as an app resource.
  local any
  for any in sim device; do
    if [[ -d "$BUILD_DIR/llvm-install-$any/lib/clang" ]]; then
      rm -rf "$BUILD_DIR/resources/clang"
      mkdir -p "$BUILD_DIR/resources"
      cp -R "$BUILD_DIR/llvm-install-$any/lib/clang" "$BUILD_DIR/resources/clang"
      break
    fi
  done
  du -sh "$OUT_DIR/LemonSeedLLVM.xcframework"/*/ "$BUILD_DIR"/llvm-stage-*/libLemonSeedLLVM.a
}

# --- main --------------------------------------------------------------------

steps=("$@")
if [[ ${#steps[@]} -eq 0 ]]; then steps=(fetch host sim device package); fi

for step in "${steps[@]}"; do
  case "$step" in
    fetch)   timed llvm-fetch do_fetch ;;
    host)    timed llvm-host-tools do_host ;;
    sim)     timed llvm-ios-sim do_ios sim ;;
    device)  timed llvm-ios-device do_ios device ;;
    package) timed llvm-package do_package ;;
    *) echo "unknown step: $step" >&2; exit 2 ;;
  esac
done
log "done: ${steps[*]}"
