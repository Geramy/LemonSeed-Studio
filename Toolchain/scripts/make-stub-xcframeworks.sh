#!/usr/bin/env bash
# Creates placeholder LemonSeedLLVM / LemonSeedWAMR XCFrameworks for any that
# have not been built, so Packages/StudioToolchain (and apps using it) build
# without the hour-long LLVM build. A placeholder holds an empty static
# library and a config header that switches the C bridge to its stub, which
# reports how to build the real framework at run time.
#
# Usage: make-stub-xcframeworks.sh [--force]   (--force replaces real ones too)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$TOOLCHAIN_DIR/versions.env"
OUT_DIR="$TOOLCHAIN_DIR/build/xcframeworks"
WORK="$TOOLCHAIN_DIR/build/stubs"
mkdir -p "$OUT_DIR" "$WORK"

make_stub() { # name macro header
  local name="$1" macro="$2" header="$3"
  local xcf="$OUT_DIR/$name.xcframework"
  if [[ -f "$xcf/Info.plist" && "${FORCE:-0}" != 1 ]]; then
    echo "$name.xcframework exists; leaving it alone"
    return
  fi
  local args=() slice sdk target
  for slice in device sim; do
    if [[ $slice == device ]]; then sdk=iphoneos; target="arm64-apple-ios$IOS_DEPLOYMENT_TARGET"
    else sdk=iphonesimulator; target="arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator"; fi
    local dir="$WORK/$name-$slice"
    rm -rf "$dir"; mkdir -p "$dir/Headers/lemonseed"
    echo "static int lst_placeholder_$slice;" >"$dir/stub.c"
    xcrun --sdk "$sdk" clang -target "$target" -c "$dir/stub.c" -o "$dir/stub.o"
    libtool -static -no_warning_for_no_symbols -o "$dir/lib$name.a" "$dir/stub.o"
    printf '/* Placeholder from make-stub-xcframeworks.sh */\n#define %s 0\n' "$macro" \
      >"$dir/Headers/lemonseed/$header"
    args+=(-library "$dir/lib$name.a" -headers "$dir/Headers")
  done
  rm -rf "$xcf"
  xcodebuild -create-xcframework "${args[@]}" -output "$xcf" >/dev/null
  echo "created placeholder $name.xcframework"
}

[[ "${1:-}" == --force ]] && FORCE=1
make_stub LemonSeedLLVM LST_HAVE_LLVM llvm_config.h
make_stub LemonSeedWAMR LST_HAVE_WAMR wamr_config.h
