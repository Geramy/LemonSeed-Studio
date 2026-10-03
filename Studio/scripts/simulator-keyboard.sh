#!/usr/bin/env bash
#
# Sets the simulator's "I/O › Keyboard › Connect Hardware Keyboard" and runs
# the keyboard UI tests against that state.
#
#   scripts/simulator-keyboard.sh off <udid>   on-screen keyboard only
#   scripts/simulator-keyboard.sh on  <udid>   hardware keyboard connected
#
# The Simulator app reads the setting when it opens a device window, so the
# app (not the device) is quit and reopened; the device stays booted.
set -euo pipefail
cd "$(dirname "$0")/.."
state="${1:?on or off}"
udid="${2:?simulator UDID}"
case "$state" in on) value=true; expect=1 ;; off) value=false; expect=0 ;; *) echo "on or off" >&2; exit 2 ;; esac

osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
sleep 2
defaults export com.apple.iphonesimulator - | /usr/bin/python3 -c '
import plistlib, sys
prefs = plistlib.loads(sys.stdin.buffer.read())
device = prefs.setdefault("DevicePreferences", {}).setdefault(sys.argv[1], {})
device["ConnectHardwareKeyboard"] = sys.argv[2] == "true"
sys.stdout.buffer.write(plistlib.dumps(prefs))
' "$udid" "$value" | defaults import com.apple.iphonesimulator -
open -a Simulator --args -CurrentDeviceUDID "$udid"
sleep 5

/opt/homebrew/bin/xcodegen --quiet
TEST_RUNNER_STUDIO_EXPECT_HARDWARE_KEYBOARD="$expect" xcodebuild -project LemonSeedStudio.xcodeproj -scheme LemonSeedStudio \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -parallel-testing-enabled NO \
  test -only-testing:StudioUITests/KeyboardTests
