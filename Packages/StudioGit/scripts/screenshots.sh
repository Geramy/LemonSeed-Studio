#!/usr/bin/env bash
#
# Capture the demo app's screens on the shared iPad simulator into
# docs/screenshots/git/ (repository root).
#
#   scripts/screenshots.sh                 every screen
#   scripts/screenshots.sh history pulls   some screens
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "$HERE/../.." && pwd)/docs/screenshots/git"
: "${SIMULATOR_ID:=36662466-8A9A-4EB2-A3A4-68B1CDF7AE7F}"
BUNDLE=com.geramyloveless.LemonSeedStudio.GitDemo
mkdir -p "$OUT"
"$HERE/Demo/build.sh" run >/dev/null
xcrun simctl status_bar "$SIMULATOR_ID" override --time 9:41 --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
screens=("$@")
[[ ${#screens[@]} -gt 0 ]] || screens=(changes conflict history repositories cloning pulls devicecode signin keys accounts)
# The simulator is shared with other apps. With FOREIGN_REFERENCE set to a
# screenshot of another app, frames that match it (another app came to the
# front) are retaken.
looks_foreign() {
  [[ -n "${FOREIGN_REFERENCE:-}" ]] || return 1
  local rmse
  # Compare the toolbar band below the status bar only.
  rmse="$(magick compare -metric RMSE "$1[2064x150+0+70]" "$FOREIGN_REFERENCE[2064x150+0+70]" null: 2>&1 | sed -E 's/.*\((.*)\).*/\1/')"
  awk -v r="$rmse" 'BEGIN { exit !(r < 0.05) }'
}
for screen in "${screens[@]}"; do
  for attempt in 1 2 3 4 5 6; do
    xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE" -screen "$screen" >/dev/null
    sleep "${DELAY:-3}"
    xcrun simctl io "$SIMULATOR_ID" screenshot "$OUT/$screen.png" >/dev/null 2>&1
    looks_foreign "$OUT/$screen.png" || break
    echo "retrying $screen (another app was in front)" >&2
  done
  echo "$OUT/$screen.png"
done
xcrun simctl status_bar "$SIMULATOR_ID" clear >/dev/null 2>&1 || true
