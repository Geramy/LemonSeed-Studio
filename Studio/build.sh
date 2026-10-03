#!/usr/bin/env bash
#
# Build and test LemonSeed Studio.
#
#   ./build.sh                 generate the project and build for the iPad simulator
#   ./build.sh test            ... and run every test (app, UI and package tests)
#   ./build.sh run             ... build, install and launch on the simulator
#   ./build.sh device          generate with the embedded GPU driver and build for iPad
#   ./build.sh install         ... device build, then install on $DEVICE
#   ./build.sh launch [args]   ... device build, install, then launch on $DEVICE
#                              (args go to the app, e.g. --selftest, --screenshots)
#
# Environment:
#   SIMULATOR         simulator name or UDID (default: "iPad Pro 13-inch (M5)")
#   CONFIGURATION     Debug (default) or Release
#   MAC_LINUXGPU_DIR  mac_linuxgpu checkout for device builds
#                     (default: third_party/mac_linuxgpu)
#   PROVISIONING      device builds only: unsigned (default; compile check),
#                     local (sign with profiles already on this Mac), or
#                     update (-allowProvisioningUpdates: Xcode may register
#                     the com.geramyloveless.LemonSeedStudio* App IDs and
#                     refresh their profiles). install/launch default to local.
#   DEVICE            CoreDevice identifier for install/launch
#   DEVICE_DESTINATION  xcodebuild destination for device builds
#                     (default: generic/platform=iOS)
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
ROOT="$(cd .. && pwd)"
: "${SIMULATOR:=iPad Pro 13-inch (M5)}"
: "${CONFIGURATION:=Debug}"
PROVISIONING_GIVEN="${PROVISIONING:-}"
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
  device|install|launch)
    : "${MAC_LINUXGPU_DIR:=$ROOT/third_party/mac_linuxgpu}"
    MAC_LINUXGPU_DIR="$(cd "$MAC_LINUXGPU_DIR" && pwd)"
    export MAC_LINUXGPU_DIR
    [[ -d "$ROOT/Engine/LSEKit/LSE.xcframework" ]] || {
      echo "Engine/LSEKit/LSE.xcframework is missing; run Engine/LSEKit/update-xcframework.sh" >&2
      exit 1
    }
    # install and launch need a signed build: local unless PROVISIONING says otherwise.
    if [[ "$1" != device && -z "$PROVISIONING_GIVEN" ]]; then PROVISIONING=local; fi
    LEMONSEED_EMBED_DEXT=YES generate
    case "$PROVISIONING" in
      unsigned) signing=(CODE_SIGNING_ALLOWED=NO) ;;
      local) signing=() ;;
      update) signing=(-allowProvisioningUpdates) ;;
      *) echo "PROVISIONING must be unsigned, local or update" >&2; exit 2 ;;
    esac
    xcb -destination "${DEVICE_DESTINATION:-generic/platform=iOS}" ${signing[@]+"${signing[@]}"} \
      MAC_LINUXGPU_DIR="$MAC_LINUXGPU_DIR" build
    app="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/LemonSeedStudio.app"
    echo "built: $app"
    if [[ "$1" != device ]]; then
      [[ "$PROVISIONING" != unsigned ]] || { echo "an unsigned build cannot be installed" >&2; exit 2; }
      : "${DEVICE:?set DEVICE to the CoreDevice identifier of the iPad}"
      # Replacing the app kills its process; with an engine open that can
      # leave the GPU driver quarantined. Close the running app's engine
      # first through the debug remote control, when it answers.
      if STUDIO_DEVICE="$DEVICE" perl -e "alarm 20; exec @ARGV" "$HERE/scripts/studioctl" engine stop >/dev/null 2>&1; then
        echo "stopped the running app's engine"
        sleep 3
      fi
      xcrun devicectl device install app --device "$DEVICE" "$app"
      if [[ "$1" == launch ]]; then
        xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" "${@:2}"
      fi
    fi
    ;;
  *)
    echo "usage: $0 [build|test|run|device|install|launch]" >&2
    exit 2
    ;;
esac
