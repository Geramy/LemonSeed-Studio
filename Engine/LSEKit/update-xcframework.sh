#!/usr/bin/env bash
#
# Puts LSE.xcframework (the engine for iOS arm64) next to Package.swift.
#
#   LSE_DIR=<LemonSeed-Engine checkout> ./update-xcframework.sh
#   LSE_XCFRAMEWORK=<path to an LSE.xcframework> ./update-xcframework.sh
#
# Copies $LSE_DIR/build/ios/LSE.xcframework (or $LSE_XCFRAMEWORK, e.g. another
# checkout's Engine/LSEKit/LSE.xcframework). With BUILD=1 it first runs that
# repository's scripts/ios/build-ios.sh, which also needs MAC_LINUXGPU_DIR
# (the mac_linuxgpu checkout whose HSA runtime it links).
set -euo pipefail
cd "$(dirname "$0")"
if [[ -n "${LSE_XCFRAMEWORK:-}" ]]; then
  src="$(cd "$LSE_XCFRAMEWORK" && pwd)"
  LSE_DIR="$src"
else
  : "${LSE_DIR:?set LSE_DIR to the LemonSeed-Engine checkout (or LSE_XCFRAMEWORK)}"
  if [[ "${BUILD:-0}" == 1 ]]; then
    bash "$LSE_DIR/scripts/ios/build-ios.sh"
  fi
  src="$LSE_DIR/build/ios/LSE.xcframework"
fi
[[ -d "$src" ]] || { echo "no $src; run with BUILD=1 or build it in $LSE_DIR" >&2; exit 1; }
[[ "$src" != "$(pwd)/LSE.xcframework" ]] || { echo "$src is the destination" >&2; exit 1; }
rm -rf LSE.xcframework
cp -R "$src" LSE.xcframework
# Xcode copies a static XCFramework's Headers/ into the products' include/.
# A top-level module.modulemap there collides with any other static
# XCFramework that has one (StudioGit's Clibgit2), so the headers move into
# Headers/LSE/, where clang still finds the LSE module.
for headers in LSE.xcframework/*/Headers; do
  [[ -f "$headers/module.modulemap" ]] || continue
  mkdir -p "$headers/LSE"
  find "$headers" -maxdepth 1 -type f -exec mv {} "$headers/LSE/" \;
done
# LSE 0.5 added lse_model_info and lse_estimate. When the library has them,
# a second module, LSEEstimate, marks it, so LSEKit can test for it with
# canImport(LSEEstimate) and older frameworks still build (callers then fall
# back to their own estimates).
for slice in LSE.xcframework/*/; do
  [[ -d "$slice/Headers/LSE" ]] || continue
  if nm -gU "$slice"/*.a 2>/dev/null | grep -c ' _lse_estimate$' >/dev/null; then
    mkdir -p "$slice/Headers/LSEEstimate"
    cat > "$slice/Headers/LSEEstimate/module.modulemap" <<'MAP'
module LSEEstimate {
  header "lse_estimate.h"
  export *
}
MAP
    cat > "$slice/Headers/LSEEstimate/lse_estimate.h" <<'HDR'
/* Present when the linked libLSE has lse_model_info and lse_estimate
 * (written by Engine/LSEKit/update-xcframework.sh). */
#include "../LSE/lse.h"
HDR
  fi
done
# LSE's per-session KV (lse_session_close) gets the same kind of marker:
# canImport(LSESessions).
for slice in LSE.xcframework/*/; do
  [[ -d "$slice/Headers/LSE" ]] || continue
  if nm -gU "$slice"/*.a 2>/dev/null | grep -c ' _lse_session_close$' >/dev/null; then
    mkdir -p "$slice/Headers/LSESessions"
    cat > "$slice/Headers/LSESessions/module.modulemap" <<'MAP'
module LSESessions {
  header "lse_sessions.h"
  export *
}
MAP
    cat > "$slice/Headers/LSESessions/lse_sessions.h" <<'HDR'
/* Present when the linked libLSE has per-session KV (lse_session_close),
 * written by Engine/LSEKit/update-xcframework.sh. */
#include "../LSE/lse.h"
HDR
  fi
done
# Device power (lse_power_prepare / lse_power_resume): canImport(LSEPower).
for slice in LSE.xcframework/*/; do
  [[ -d "$slice/Headers/LSE" ]] || continue
  if nm -gU "$slice"/*.a 2>/dev/null | grep -c ' _lse_power_prepare$' >/dev/null; then
    mkdir -p "$slice/Headers/LSEPower"
    cat > "$slice/Headers/LSEPower/module.modulemap" <<'MAP'
module LSEPower {
  header "lse_power.h"
  export *
}
MAP
    cat > "$slice/Headers/LSEPower/lse_power.h" <<'HDR'
/* Present when the linked libLSE has device power control
 * (lse_power_prepare, lse_power_resume), written by
 * Engine/LSEKit/update-xcframework.sh. */
#include "../LSE/lse.h"
HDR
  fi
done
echo "LSEKit: $(pwd)/LSE.xcframework from $(git -C "$LSE_DIR" describe --always --dirty 2>/dev/null || echo "$LSE_DIR")"
