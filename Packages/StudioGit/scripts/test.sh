#!/usr/bin/env bash
#
# Run the StudioGit test suites.
#
#   scripts/test.sh                      all suites with `swift test` on the Mac
#   scripts/test.sh GitKitTests          a filter (target, Suite, or Suite/test)
#   scripts/test.sh --ios [filter]       on the shared iPad simulator instead
#
# The Mac run is the default: it needs no simulator and covers the same code
# (Clibgit2.xcframework has a macOS slice for this). --ios uses only the
# shared "iPad Pro 13-inch (M5)" simulator below, serially; it never creates
# or boots another device.
#
# Environment:
#   SIMULATOR_ID                 simulator for --ios (default: the shared one)
#   STUDIOGIT_NETWORK_TESTS=0    skip tests that reach github.com / gitlab.com
#   STUDIOGIT_SSH_TEST_*         set by scripts/ssh-test-server.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
"$HERE/scripts/build-libgit2.sh" >/dev/null
cd "$HERE"

ios=0
if [[ "${1:-}" == --ios ]]; then ios=1; shift; fi
filter="${1:-}"

if [[ $ios == 0 ]]; then
  exec swift test ${filter:+--filter "$filter"}
fi

: "${SIMULATOR_ID:=36662466-8A9A-4EB2-A3A4-68B1CDF7AE7F}"
# xcodebuild passes TEST_RUNNER_<name> into the test process as <name>.
env_args=()
while IFS='=' read -r name value; do
  env_args+=("TEST_RUNNER_$name=$value")
done < <(env | grep '^STUDIOGIT_' || true)

exec env ${env_args[@]+"${env_args[@]}"} xcodebuild test \
  -scheme StudioGit-Package \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  -derivedDataPath "$HERE/build/DerivedData" \
  ${filter:+-only-testing:"$filter"}
