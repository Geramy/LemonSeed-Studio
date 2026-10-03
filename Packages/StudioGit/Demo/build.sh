#!/usr/bin/env bash
#
# Build the StudioGit demo app for the iPad simulator (no signing).
#
#   Demo/build.sh                build
#   Demo/build.sh run [args]     build, install and launch on $SIMULATOR_ID
#                                (default: the shared iPad Pro 13-inch (M5))
#
# Launch arguments select a screen, e.g. `-screen history`; see App/DemoApp.swift.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SIMULATOR_ID:=36662466-8A9A-4EB2-A3A4-68B1CDF7AE7F}"
"$HERE/../scripts/build-libgit2.sh" >/dev/null
/opt/homebrew/bin/xcodegen --spec "$HERE/project.yml" --project "$HERE" --quiet
xcodebuild -project "$HERE/StudioGitDemo.xcodeproj" -scheme StudioGitDemo -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$HERE/../build/DemoDerivedData" \
  CODE_SIGNING_ALLOWED=NO build | grep -E "^[^ ].*(error|warning): |\*\* BUILD" || true
APP="$HERE/../build/DemoDerivedData/Build/Products/Debug-iphonesimulator/StudioGitDemo.app"
[[ -d "$APP" ]] || { echo "build failed" >&2; exit 1; }
if [[ "${1:-}" == run ]]; then
  shift
  xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
  xcrun simctl install "$SIMULATOR_ID" "$APP"
  xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" com.geramyloveless.LemonSeedStudio.GitDemo "$@"
fi
