#!/usr/bin/env bash
#
# Puts LSE.xcframework (the engine for iOS arm64) next to Package.swift.
#
#   LSE_DIR=<LemonSeed-Engine checkout> ./update-xcframework.sh
#
# Copies $LSE_DIR/build/ios/LSE.xcframework. With BUILD=1 it first runs that
# repository's scripts/ios/build-ios.sh, which also needs MAC_LINUXGPU_DIR
# (the mac_linuxgpu checkout whose HSA runtime it links).
set -euo pipefail
cd "$(dirname "$0")"
: "${LSE_DIR:?set LSE_DIR to the LemonSeed-Engine checkout}"
if [[ "${BUILD:-0}" == 1 ]]; then
  bash "$LSE_DIR/scripts/ios/build-ios.sh"
fi
src="$LSE_DIR/build/ios/LSE.xcframework"
[[ -d "$src" ]] || { echo "no $src; run with BUILD=1 or build it in $LSE_DIR" >&2; exit 1; }
rm -rf LSE.xcframework
cp -R "$src" LSE.xcframework
echo "LSEKit: $(pwd)/LSE.xcframework from $(git -C "$LSE_DIR" describe --always --dirty 2>/dev/null || echo "$LSE_DIR")"
