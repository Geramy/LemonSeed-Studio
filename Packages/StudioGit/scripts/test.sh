#!/usr/bin/env bash
#
# Run the StudioGit test suites on an iPad simulator.
#
#   scripts/test.sh                 all tests
#   scripts/test.sh GitKitTests     one test target (or Target/Suite)
#
# Environment:
#   SIMULATOR   simulator name or UDID (default: "iPad Pro 13-inch (M5)" on iOS 26.5)
#   STUDIOGIT_NETWORK_TESTS=0      skip tests that clone from github.com
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
"$HERE/scripts/build-libgit2.sh" >/dev/null

if [[ -z "${SIMULATOR:-}" ]]; then
  SIMULATOR="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
for runtime, devices in sorted(data.items(), reverse=True):
    if "iOS-26-5" not in runtime: continue
    for d in devices:
        if d["name"].startswith("iPad Pro 13-inch (M5)"):
            print(d["udid"]); sys.exit(0)
')"
fi
[[ -n "$SIMULATOR" ]] || { echo "no iPad Pro 13-inch (M5) simulator on iOS 26.5" >&2; exit 1; }

only=()
[[ $# -gt 0 ]] && only=(-only-testing:"$1")
env_args=()
[[ -n "${STUDIOGIT_NETWORK_TESTS:-}" ]] && env_args+=(TEST_RUNNER_STUDIOGIT_NETWORK_TESTS="$STUDIOGIT_NETWORK_TESTS")
[[ -n "${STUDIOGIT_SSH_TEST_DIR:-}" ]] && env_args+=(TEST_RUNNER_STUDIOGIT_SSH_TEST_DIR="$STUDIOGIT_SSH_TEST_DIR")

cd "$HERE"
exec env ${env_args[@]+"${env_args[@]}"} xcodebuild test \
  -scheme StudioGit-Package \
  -destination "id=$SIMULATOR" \
  -derivedDataPath "$HERE/build/DerivedData" \
  ${only[@]+"${only[@]}"}
