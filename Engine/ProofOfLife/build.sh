#!/usr/bin/env bash
#
# Build, install and launch the LemonSeed Studio iPad proof of life.
#
#   ./build.sh                 generate the project and build for an iOS device
#   ./build.sh install         ... then install on $DEVICE
#   ./build.sh run             ... then install and launch on $DEVICE
#   ./build.sh test            macOS tests only (no iOS build): the firmware
#                              servicer against the bundled firmware set
#
# Launch arguments (devicectl ... process launch ... <bundle id> <args>):
#   --auto-probe               probe, then write the report
#   --auto-bringup             probe, initialize the GPU (InitDevice with the
#                              firmware servicer), then write the report
#   --bringup-timeout=SECONDS  InitDevice wait before it is reported hung (300)
# The report goes to stdout and the app's Documents/probe-report.txt.
#
# Environment:
#   MAC_LINUXGPU_DIR  mac_linuxgpu checkout the dext is compiled from
#                     (default: third_party/mac_linuxgpu). Its first build
#                     runs `make lib-dext` there, which bootstraps it.
#   DEVICE            CoreDevice identifier, name or UDID for devicectl
#   DESTINATION       xcodebuild destination (default: generic/platform=iOS)
#   CONFIGURATION     Debug (default) or Release
#   PROVISIONING      local (default): sign with profiles already on this Mac
#                     and never contact the developer portal.
#                     update: pass -allowProvisioningUpdates, which lets Xcode
#                     register App IDs, add capabilities and create profiles.
#                     unsigned: CODE_SIGNING_ALLOWED=NO (compile check only;
#                     cannot be installed).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
ROOT="$(cd ../.. && pwd)"

: "${MAC_LINUXGPU_DIR:=$ROOT/third_party/mac_linuxgpu}"
MAC_LINUXGPU_DIR="$(cd "$MAC_LINUXGPU_DIR" && pwd)"
export MAC_LINUXGPU_DIR
: "${DESTINATION:=generic/platform=iOS}"
: "${CONFIGURATION:=Debug}"
: "${PROVISIONING:=local}"
case "$PROVISIONING" in
  local) signing=() ;;
  update) signing=(-allowProvisioningUpdates) ;;
  unsigned) signing=(CODE_SIGNING_ALLOWED=NO) ;;
  *) echo "PROVISIONING must be local, update or unsigned" >&2; exit 2 ;;
esac
DERIVED="$HERE/build/DerivedData"
APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/LemonSeedStudio.app"
BUNDLE_ID=com.geramyloveless.LemonSeedStudio

pinned="$(git -C "$ROOT" ls-tree HEAD third_party/mac_linuxgpu | awk '{print $3}')"
actual="$(git -C "$MAC_LINUXGPU_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$pinned" && "$pinned" != "$actual" ]]; then
  echo "note: $MAC_LINUXGPU_DIR is at $actual; the submodule pin is $pinned" >&2
fi

if [[ "${1:-build}" == test ]]; then
  # The servicer source the app compiles, run on macOS against a mailbox in
  # anonymous memory and the firmware root the app bundles.
  out="$HERE/build/test"
  mkdir -p "$out"
  "$HERE/scripts/bundle-firmware.sh" "$MAC_LINUXGPU_DIR" "$out/Firmware"
  xcrun clang -std=gnu11 -O1 -Wall -Wextra -Werror \
    -I"$MAC_LINUXGPU_DIR/host" -I"$MAC_LINUXGPU_DIR/linuxu/headers" \
    "$HERE/Tests/fw_service_test.c" "$MAC_LINUXGPU_DIR/host/fw_mailbox_service.c" \
    -o "$out/fw_service_test"
  "$out/fw_service_test" "$out/Firmware" "$out/Firmware/firmware.lock"
  exit 0
fi

/opt/homebrew/bin/xcodegen --spec "$HERE/project.yml" --project "$HERE"

xcodebuild \
  -project "$HERE/ProofOfLife.xcodeproj" \
  -scheme LemonSeedStudio \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  ${signing[@]+"${signing[@]}"} \
  MAC_LINUXGPU_DIR="$MAC_LINUXGPU_DIR" \
  ${DEXT_ENTITLEMENTS:+DEXT_ENTITLEMENTS="$DEXT_ENTITLEMENTS"} \
  build

echo "built: $APP"

case "${1:-build}" in
  build) ;;
  install|run)
    [[ "$PROVISIONING" != unsigned ]] || { echo "an unsigned build cannot be installed" >&2; exit 2; }
    : "${DEVICE:?set DEVICE to the CoreDevice identifier of the iPad}"
    xcrun devicectl device install app --device "$DEVICE" "$APP"
    if [[ "$1" == run ]]; then
      xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID"
    fi
    ;;
  *) echo "usage: $0 [build|install|run|test]" >&2; exit 2 ;;
esac
