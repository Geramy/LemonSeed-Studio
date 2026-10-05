#!/usr/bin/env bash
# Builds what user programs link beyond wasi-libc and adds it to the
# WASIToolchain resources (Toolchain/build/resources/WASIToolchain):
#
#   extensions/sockets/include/   <sys/socket.h> and <netdb.h> overlays and
#                                 wasi_socket_ext.h, ahead of the sysroot, so
#                                 standard BSD socket code compiles unchanged
#   extensions/sockets/lib/<t>/   libwasi_socket_ext.a: WAMR's socket
#                                 extension (socket, bind, connect, listen,
#                                 getaddrinfo, options) plus gai_strerror,
#                                 getnameinfo and gethostbyname
#
# for each sysroot target (wasm32-wasip1, wasm32-wasip1-threads). Programs
# that use them run on WAMR, which implements the calls in libc-wasi.
#
# The archives are compiled with the same LLVM release the app's compiler is
# (llvm@21 from Homebrew: clang and llvm-ar 21.1.x), so wasm-ld 21 in the app
# links them without feature or relocation surprises. Run after
# fetch-wasi-sysroot.sh and build-wamr-ios.sh (for the WAMR source).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../versions.env
source "$TOOLCHAIN_DIR/versions.env"

BUILD_DIR="$TOOLCHAIN_DIR/build"
RES="$BUILD_DIR/resources/WASIToolchain"
WAMR_SRC="$BUILD_DIR/src/wasm-micro-runtime-WAMR-$WAMR_VERSION"
SOCKET_SRC="$WAMR_SRC/core/iwasm/libraries/lib-socket"
EXT_SRC="$TOOLCHAIN_DIR/extensions/sockets"
LLVM_MAJOR="${LLVM_VERSION%%.*}"
LLVM_BIN="${LLVM_BIN:-$(brew --prefix "llvm@$LLVM_MAJOR")/bin}"
CC="$LLVM_BIN/clang"
AR="$LLVM_BIN/llvm-ar"

[[ -x "$CC" ]] || { echo "need clang $LLVM_MAJOR: brew install llvm@$LLVM_MAJOR" >&2; exit 1; }
"$CC" --version | head -1 | grep -q "version $LLVM_MAJOR\." ||
  { echo "$CC is not clang $LLVM_MAJOR" >&2; exit 1; }
[[ -d "$RES/sysroot" ]] || { echo "run fetch-wasi-sysroot.sh first" >&2; exit 1; }
[[ -f "$SOCKET_SRC/inc/wasi_socket_ext.h" ]] || { echo "run build-wamr-ios.sh first (WAMR source)" >&2; exit 1; }

OUT="$RES/extensions/sockets"
rm -rf "$OUT"
mkdir -p "$OUT/include/sys"
cp "$EXT_SRC/include/sys/socket.h" "$OUT/include/sys/socket.h"
cp "$EXT_SRC/include/netdb.h" "$OUT/include/netdb.h"

# WAMR's header redefines constants wasi-libc already defines (SO_RCVTIMEO
# and the like) with the values its implementation expects. #undef each one
# first, so its values win without a redefinition warning in every build.
awk '/^#define [A-Z_0-9]+ / { print "#undef " $2 } { print }' \
  "$SOCKET_SRC/inc/wasi_socket_ext.h" >"$OUT/include/wasi_socket_ext.h"

for target in $(ls "$RES/sysroot/lib"); do
  flags=(--target="$target" --sysroot="$RES/sysroot" -resource-dir "$RES/clang" -O2
         -isystem "$OUT/include" -Wno-unused-parameter)
  [[ "$target" == *-threads ]] && flags+=(-pthread)
  obj="$BUILD_DIR/socket-ext/$target"
  rm -rf "$obj"
  mkdir -p "$obj" "$OUT/lib/$target"
  "$CC" "${flags[@]}" -c "$SOCKET_SRC/src/wasi/wasi_socket_ext.c" -o "$obj/wasi_socket_ext.o"
  "$CC" "${flags[@]}" -c "$EXT_SRC/src/netdb_extra.c" -o "$obj/netdb_extra.o"
  "$AR" rcs "$OUT/lib/$target/libwasi_socket_ext.a" "$obj/wasi_socket_ext.o" "$obj/netdb_extra.o"
  echo "$target: $(du -h "$OUT/lib/$target/libwasi_socket_ext.a" | cut -f1)"
done
