#!/usr/bin/env bash
#
# Build, install and launch the LemonSeed Studio iPad proof of life.
#
#   ./build.sh                 generate the project and build for an iOS device
#   ./build.sh install         ... then install on $DEVICE
#   ./build.sh run             ... then install and launch on $DEVICE
#
# Environment:
#   MAC_LINUXGPU_DIR  mac_linuxgpu checkout the dext is compiled from
#                     (default: third_party/mac_linuxgpu). Its first build
#                     runs `make lib-dext` there, which bootstraps it.
#   DEVICE            CoreDevice identifier, name or UDID for devicectl
#   DESTINATION       xcodebuild destination (default: generic/platform=iOS)
#   CONFIGURATION     Debug (default) or Release
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
ROOT="$(cd ../.. && pwd)"

: "${MAC_LINUXGPU_DIR:=$ROOT/third_party/mac_linuxgpu}"
MAC_LINUXGPU_DIR="$(cd "$MAC_LINUXGPU_DIR" && pwd)"
export MAC_LINUXGPU_DIR
: "${DESTINATION:=generic/platform=iOS}"
: "${CONFIGURATION:=Debug}"
DERIVED="$HERE/build/DerivedData"
APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/LemonSeedStudio.app"
BUNDLE_ID=com.geramyloveless.MacAMDGPUHost

pinned="$(git -C "$ROOT" ls-tree HEAD third_party/mac_linuxgpu | awk '{print $3}')"
actual="$(git -C "$MAC_LINUXGPU_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$pinned" && "$pinned" != "$actual" ]]; then
  echo "note: $MAC_LINUXGPU_DIR is at $actual; the submodule pin is $pinned" >&2
fi

/opt/homebrew/bin/xcodegen --spec "$HERE/project.yml" --project "$HERE"

xcodebuild \
  -project "$HERE/ProofOfLife.xcodeproj" \
  -scheme LemonSeedStudio \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  MAC_LINUXGPU_DIR="$MAC_LINUXGPU_DIR" \
  build

echo "built: $APP"

case "${1:-build}" in
  build) ;;
  install|run)
    : "${DEVICE:?set DEVICE to the iPad's CoreDevice identifier}"
    xcrun devicectl device install app --device "$DEVICE" "$APP"
    if [[ "$1" == run ]]; then
      xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID"
    fi
    ;;
  *) echo "usage: $0 [build|install|run]" >&2; exit 2 ;;
esac
