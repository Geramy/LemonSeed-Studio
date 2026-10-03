#!/usr/bin/env bash
#
# Build libgit2 for iPadOS from pinned source releases and package it as
# Clibgit2.xcframework (iOS device arm64 + iOS simulator arm64).
#
#   Packages/StudioGit/scripts/build-libgit2.sh            build (cached)
#   Packages/StudioGit/scripts/build-libgit2.sh clean      remove build/
#
# Output (gitignored):
#   Packages/StudioGit/build/Clibgit2.xcframework
#
# What goes in:
#   libgit2  1.9.7   GPL-2.0 with linking exception  (HTTPS via OpenSSL, SSH via libssh2)
#   libssh2  1.11.1  BSD-3-Clause                    (crypto backend: OpenSSL)
#   OpenSSL  3.5.9   Apache-2.0                      (LTS branch; TLS for HTTPS and libssh2 crypto)
#   zlib     from the iOS SDK (libz.tbd), linked by the module map
#   iconv    from the iOS SDK (libiconv.tbd), linked by the module map
#
# TLS choice: libgit2's SecureTransport backend is deprecated by Apple and
# libssh2 has no Apple-native crypto backend, so one OpenSSL build serves
# both. mbedTLS works for libgit2 HTTPS, but libssh2's mbedTLS backend lacks
# ed25519 host and user keys. GitKit verifies server certificates against the
# system trust store first (SecTrust, in the certificate callback) and falls
# back to the bundled Mozilla CA list that OpenSSL checks.
#
# The four static libraries are merged into one relocatable object whose
# only global symbols are git_* and libssh2_*: OpenSSL's symbols become
# private, so another OpenSSL elsewhere in the app cannot collide with it.
#
# Environment:
#   IOS_MIN      deployment target (default 26.2)
#   JOBS         parallel jobs (default: CPU count)
#   SOURCE_CACHE where tarballs are kept (default build/src-cache)
set -euo pipefail

LIBGIT2_VERSION=1.9.7
LIBGIT2_SHA256=1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7
LIBGIT2_URL="https://github.com/libgit2/libgit2/archive/refs/tags/v${LIBGIT2_VERSION}.tar.gz"

LIBSSH2_VERSION=1.11.1
LIBSSH2_SHA256=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
LIBSSH2_URL="https://github.com/libssh2/libssh2/releases/download/libssh2-${LIBSSH2_VERSION}/libssh2-${LIBSSH2_VERSION}.tar.gz"

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
BUILD="$PKG/build"
: "${IOS_MIN:=26.2}"
: "${JOBS:=$(sysctl -n hw.ncpu)}"
: "${SOURCE_CACHE:=$BUILD/src-cache}"
XCFRAMEWORK="$BUILD/Clibgit2.xcframework"
STAMP="$BUILD/.clibgit2-stamp"
STAMP_VALUE="libgit2-$LIBGIT2_VERSION libssh2-$LIBSSH2_VERSION openssl-$OPENSSL_VERSION ios-$IOS_MIN script-$(shasum -a 256 "$0" | cut -c1-16)"

if [[ "${1:-}" == clean ]]; then
  rm -rf "$BUILD"
  exit 0
fi

if [[ -d "$XCFRAMEWORK" && -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" ]]; then
  echo "Clibgit2.xcframework is up to date ($STAMP_VALUE)"
  exit 0
fi

for tool in cmake perl xcrun xcodebuild libtool; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

log() { printf '\n==> %s\n' "$*"; }

fetch() { # name url sha256
  local name="$1" url="$2" sha="$3" file="$SOURCE_CACHE/$1.tar.gz"
  mkdir -p "$SOURCE_CACHE"
  if [[ ! -f "$file" ]] || ! echo "$sha  $file" | shasum -a 256 -c - >/dev/null 2>&1; then
    log "download $name"
    curl -fsSL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  echo "$sha  $file" | shasum -a 256 -c - >/dev/null || {
    echo "checksum mismatch for $file" >&2; exit 1; }
}

unpack() { # name destdir
  local name="$1" dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xzf "$SOURCE_CACHE/$name.tar.gz" -C "$dest" --strip-components 1
}

fetch libgit2 "$LIBGIT2_URL" "$LIBGIT2_SHA256"
fetch libssh2 "$LIBSSH2_URL" "$LIBSSH2_SHA256"
fetch openssl "$OPENSSL_URL" "$OPENSSL_SHA256"

build_platform() { # sdk  (iphoneos | iphonesimulator)
  local sdk="$1"
  local root="$BUILD/$sdk"
  local prefix="$root/prefix"
  local sysroot min_flag target cmake_sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  if [[ "$sdk" == iphoneos ]]; then
    min_flag="-mios-version-min=$IOS_MIN"
    target="arm64-apple-ios$IOS_MIN"
  else
    min_flag="-mios-simulator-version-min=$IOS_MIN"
    target="arm64-apple-ios$IOS_MIN-simulator"
  fi
  cmake_sysroot="$sdk"
  rm -rf "$root"
  mkdir -p "$root" "$prefix"

  # OpenSSL -----------------------------------------------------------------
  log "OpenSSL $OPENSSL_VERSION ($sdk)"
  unpack openssl "$root/openssl"
  local ossl_target=ios64-xcrun
  [[ "$sdk" == iphonesimulator ]] && ossl_target=iossimulator-arm64-xcrun
  (
    cd "$root/openssl"
    ./Configure "$ossl_target" \
      --prefix="$prefix" --openssldir=/var/empty --libdir=lib \
      no-shared no-module no-dso no-engine no-tests no-apps no-docs \
      no-ui-console no-legacy no-comp \
      "$min_flag" -fvisibility=hidden >"$root/openssl-configure.log"
    make -j"$JOBS" build_libs >"$root/openssl-build.log" 2>&1
    make install_dev >"$root/openssl-install.log" 2>&1
  )

  local cmake_common=(
    -G Ninja
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT="$cmake_sysroot"
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
    -DCMAKE_C_FLAGS="-target $target"
    -Wno-dev
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_PREFIX_PATH="$prefix"
    -DCMAKE_FIND_ROOT_PATH="$prefix;$sysroot"
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH
    -DBUILD_SHARED_LIBS=OFF
    -DOPENSSL_ROOT_DIR="$prefix"
    -DOPENSSL_USE_STATIC_LIBS=ON
  )
  local generator_tool=ninja
  command -v ninja >/dev/null || { cmake_common[1]="Unix Makefiles"; generator_tool=make; }

  # libssh2 -----------------------------------------------------------------
  log "libssh2 $LIBSSH2_VERSION ($sdk)"
  unpack libssh2 "$root/libssh2"
  cmake -S "$root/libssh2" -B "$root/libssh2/_build" "${cmake_common[@]}" \
    -DCRYPTO_BACKEND=OpenSSL \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB_COMPRESSION=ON \
    -DHIDE_SYMBOLS=OFF \
    -DLIBSSH2_NO_DEPRECATED=OFF \
    >"$root/libssh2-configure.log"
  cmake --build "$root/libssh2/_build" --parallel "$JOBS" >"$root/libssh2-build.log"
  cmake --install "$root/libssh2/_build" >"$root/libssh2-install.log"

  # libgit2 -----------------------------------------------------------------
  log "libgit2 $LIBGIT2_VERSION ($sdk)"
  unpack libgit2 "$root/libgit2"
  # The memory-credentials probe links a test program against libssh2; give
  # it OpenSSL and zlib so it passes for a static libssh2.
  cmake -S "$root/libgit2" -B "$root/libgit2/_build" "${cmake_common[@]}" \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_FUZZERS=OFF \
    -DUSE_SSH=libssh2 \
    -DUSE_HTTPS=OpenSSL \
    -DUSE_SHA1=CollisionDetection \
    -DUSE_SHA256=HTTPS \
    -DUSE_BUNDLED_ZLIB=OFF \
    -DREGEX_BACKEND=builtin \
    -DUSE_HTTP_PARSER=builtin \
    -DUSE_NTLMCLIENT=OFF \
    -DUSE_GSSAPI=OFF \
    -DUSE_ICONV=ON \
    -DUSE_THREADS=ON \
    -DLIBSSH2_INCLUDE_DIR="$prefix/include" \
    -DLIBSSH2_LIBRARY="$prefix/lib/libssh2.a" \
    -DCMAKE_REQUIRED_LIBRARIES="$prefix/lib/libssh2.a;$prefix/lib/libssl.a;$prefix/lib/libcrypto.a;z" \
    -DPKG_CONFIG_EXECUTABLE=/usr/bin/false \
    >"$root/libgit2-configure.log"
  grep -q "GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS 1" "$root/libgit2/_build/gen_headers/git2_features.h" \
    || echo "note: libssh2 in-memory key credentials are disabled" >&2
  cmake --build "$root/libgit2/_build" --parallel "$JOBS" >"$root/libgit2-build.log"
  cmake --install "$root/libgit2/_build" >"$root/libgit2-install.log"

  # Merge -------------------------------------------------------------------
  log "merge static libraries ($sdk)"
  local exports="$root/exports.txt"
  # Export exactly the public (non-private-extern) symbols of libgit2 and
  # libssh2; everything else, OpenSSL included, becomes private.
  nm -gUm "$prefix/lib/libgit2.a" "$prefix/lib/libssh2.a" \
    | grep ' external ' | grep -v 'private external' \
    | awk '{print $NF}' | sort -u >"$exports"
  xcrun --sdk "$sdk" ld -r -arch arm64 \
    -platform_version "$([[ $sdk == iphoneos ]] && echo ios || echo ios-simulator)" "$IOS_MIN" "$IOS_MIN" \
    -exported_symbols_list "$exports" \
    -o "$root/Clibgit2.o" \
    -all_load "$prefix/lib/libgit2.a" "$prefix/lib/libssh2.a" "$prefix/lib/libssl.a" "$prefix/lib/libcrypto.a"
  mkdir -p "$root/lib"
  libtool -static -o "$root/lib/libClibgit2.a" "$root/Clibgit2.o" 2>/dev/null
  if nm -gU "$root/lib/libClibgit2.a" | awk '{print $3}' | grep -E '^_(SSL|EVP|OPENSSL|CRYPTO|BIO)_' | head -1 | grep -q .; then
    echo "OpenSSL symbols leaked out of libClibgit2.a" >&2; exit 1
  fi
}

build_platform iphoneos
build_platform iphonesimulator

# Headers + module map ------------------------------------------------------
log "headers"
HEADERS="$BUILD/headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp -R "$BUILD/iphoneos/prefix/include/git2" "$HEADERS/"
cp "$BUILD/iphoneos/prefix/include/git2.h" "$HEADERS/"
cp "$BUILD/iphoneos/prefix/include/libssh2.h" "$HEADERS/"
cp "$BUILD/iphoneos/prefix/include/libssh2_publickey.h" "$HEADERS/"
cp "$BUILD/iphoneos/prefix/include/libssh2_sftp.h" "$HEADERS/"
cat >"$HEADERS/Clibgit2.h" <<'EOF'
/* Umbrella header for the Clibgit2 module (generated by build-libgit2.sh). */
#ifndef CLIBGIT2_H
#define CLIBGIT2_H
#include "git2.h"
#include "git2/sys/filter.h"
#include "git2/sys/repository.h"
#include "git2/sys/odb_backend.h"
#include "git2/sys/credential.h"
#include "git2/sys/errors.h"
#include "libssh2.h"
#endif
EOF
cat >"$HEADERS/module.modulemap" <<'EOF'
module Clibgit2 {
    header "Clibgit2.h"
    export *
    link "z"
    link "iconv"
}
EOF

# XCFramework -----------------------------------------------------------------
log "xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$BUILD/iphoneos/lib/libClibgit2.a" -headers "$HEADERS" \
  -library "$BUILD/iphonesimulator/lib/libClibgit2.a" -headers "$HEADERS" \
  -output "$XCFRAMEWORK" >/dev/null

# License texts for the acknowledgements screen.
mkdir -p "$BUILD/licenses"
cp "$BUILD/iphoneos/libgit2/COPYING" "$BUILD/licenses/libgit2-COPYING.txt"
cp "$BUILD/iphoneos/libssh2/COPYING" "$BUILD/licenses/libssh2-COPYING.txt"
cp "$BUILD/iphoneos/openssl/LICENSE.txt" "$BUILD/licenses/openssl-LICENSE.txt"

echo "$STAMP_VALUE" >"$STAMP"
log "done: $XCFRAMEWORK"
du -sh "$XCFRAMEWORK"
