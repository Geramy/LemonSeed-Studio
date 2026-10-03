#!/usr/bin/env bash
#
# Build and test LemonSeed Studio.
#
#   ./build.sh                 generate the project and build for the iPad simulator
#   ./build.sh test            ... and run every test (app, UI and package tests)
#   ./build.sh run             ... build, install and launch on the simulator
#   ./build.sh device          generate with the embedded GPU driver and build for iPad
#
# Environment:
#   SIMULATOR         simulator name or UDID (default: "iPad Pro 13-inch (M5)")
#   CONFIGURATION     Debug (default) or Release
#   MAC_LINUXGPU_DIR  mac_linuxgpu checkout for device builds
#                     (default: third_party/mac_linuxgpu)
#   PROVISIONING      device builds only: unsigned (default; compile check),
#                     or local (sign with profiles already on this Mac).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
ROOT="$(cd .. && pwd)"
: "${SIMULATOR:=iPad Pro 13-inch (M5)}"
: "${CONFIGURATION:=Debug}"
: "${PROVISIONING:=unsigned}"
DERIVED="$HERE/build/DerivedData"
BUNDLE_ID=com.geramyloveless.LemonSeedStudio

if [[ "$SIMULATOR" =~ ^[0-9A-F-]{36}$ ]]; then
  DESTINATION="platform=iOS Simulator,id=$SIMULATOR"
else
  DESTINATION="platform=iOS Simulator,name=$SIMULATOR"
fi

generate() {
  /opt/homebrew/bin/xcodegen --spec "$HERE/project.yml" --project "$HERE" --quiet
}

xcb() {
  xcodebuild -project "$HERE/LemonSeedStudio.xcodeproj" -scheme LemonSeedStudio \
    -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation "$@"
}

case "${1:-build}" in
  build)
    LEMONSEED_EMBED_DEXT=NO generate
    xcb -destination "$DESTINATION" build
    ;;
  test)
    LEMONSEED_EMBED_DEXT=NO generate
    xcb -destination "$DESTINATION" -parallel-testing-enabled NO test
    ;;
  run)
    LEMONSEED_EMBED_DEXT=NO generate
    xcb -destination "$DESTINATION" build
    app="$DERIVED/Build/Products/$CONFIGURATION-iphonesimulator/LemonSeedStudio.app"
    xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
    xcrun simctl install "$SIMULATOR" "$app"
    xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID" "${@:2}"
    ;;
  device)
    : "${MAC_LINUXGPU_DIR:=$ROOT/third_party/mac_linuxgpu}"
    MAC_LINUXGPU_DIR="$(cd "$MAC_LINUXGPU_DIR" && pwd)"
    export MAC_LINUXGPU_DIR
    LEMONSEED_EMBED_DEXT=YES generate
    case "$PROVISIONING" in
      unsigned) signing=(CODE_SIGNING_ALLOWED=NO) ;;
      local) signing=() ;;
      *) echo "PROVISIONING must be unsigned or local" >&2; exit 2 ;;
    esac
    xcb -destination "generic/platform=iOS" ${signing[@]+"${signing[@]}"} MAC_LINUXGPU_DIR="$MAC_LINUXGPU_DIR" build
    ;;
  *)
    echo "usage: $0 [build|test|run|device]" >&2
    exit 2
    ;;
esac
