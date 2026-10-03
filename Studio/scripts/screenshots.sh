#!/usr/bin/env bash
#
# Captures the README screenshots into docs/screenshots/shell.
#
#   scripts/screenshots.sh <simulator-udid> [sample-folder]
#
# The sample folder (default: a fresh clone of third_party/amdgpu_mtopg)
# is copied into the app's Projects folder as "amdgpu_mtopg".
set -euo pipefail
cd "$(dirname "$0")/.."
udid="${1:?simulator UDID}"
root="$(cd .. && pwd)"
out="$root/docs/screenshots/shell"
sample="${2:-}"
if [[ -z "$sample" ]]; then
  sample="$(mktemp -d)/amdgpu_mtopg"
  source="$root/third_party/amdgpu_mtopg"
  [[ -d "$source/Sources" ]] || source="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/../third_party/amdgpu_mtopg"
  git clone -q "$source" "$sample"
fi
mkdir -p "$out"
xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 || true
/opt/homebrew/bin/xcodegen --quiet
TEST_RUNNER_STUDIO_SCREENSHOT_DIR="$out" TEST_RUNNER_STUDIO_SAMPLE_PATH="$sample" \
xcodebuild -project LemonSeedStudio.xcodeproj -scheme LemonSeedStudio \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -parallel-testing-enabled NO \
  test -only-testing:StudioUITests/ScreenshotTests
ls -1 "$out"
