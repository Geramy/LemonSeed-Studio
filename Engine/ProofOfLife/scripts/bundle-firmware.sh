#!/usr/bin/env bash
#
# Copy the locked linux-firmware set into a firmware root for the app bundle.
#
#   scripts/bundle-firmware.sh <mac_linuxgpu dir> <destination>
#
# Every "file" entry of <mac_linuxgpu>/firmware/firmware.lock is copied from
# <mac_linuxgpu>/build/firmware/<path> to <destination>/<path> (amdgpu images
# land in <destination>/amdgpu/, WHENCE and LICENSES/LICENSE.amdgpu next to
# them as in linux-firmware), and the copy's SHA-256 and size are checked
# against the lock. The lock itself is copied too, for provenance. The
# destination is the firmware servicer's root: request_firmware() names such
# as "amdgpu/psp_14_0_2_sos.bin" resolve under it. No file list here belongs
# to a particular GPU; the lock decides what ships.
#
# When the source is missing or does not match, mac_linuxgpu's
# scripts/fetch-firmware.sh fetches it (network). FIRMWARE_SRC overrides the
# source directory (no fetch is attempted for an override).
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <mac_linuxgpu dir> <destination>" >&2; exit 2; }
MLG="$1"
DEST="$2"
LOCK="$MLG/firmware/firmware.lock"
SRC="${FIRMWARE_SRC:-$MLG/build/firmware}"

die() { echo "bundle-firmware: error: $*" >&2; exit 1; }
[[ -f "$LOCK" ]] || die "missing $LOCK"

sha256() { /usr/bin/shasum -a 256 "$1" | awk '{ print $1 }'; }
size_of() { wc -c < "$1" | tr -d ' '; }
matches() { [[ -f "$1" && "$(size_of "$1")" == "$3" && "$(sha256 "$1")" == "$2" ]]; }
entries() { awk '$1 == "file" { print $2, $3, $4 }' "$LOCK"; }

source_ok() {
  local path sha size
  while read -r path sha size; do
    matches "$SRC/$path" "$sha" "$size" || return 1
  done < <(entries)
}

if ! source_ok; then
  [[ -z "${FIRMWARE_SRC:-}" ]] || die "$SRC does not match $LOCK"
  echo "bundle-firmware: fetching the locked firmware with $MLG/scripts/fetch-firmware.sh"
  "$MLG/scripts/fetch-firmware.sh"
fi

rm -rf "$DEST"
mkdir -p "$DEST"
count=0
bytes=0
while read -r path sha size; do
  [[ "$path" != /* && "$path" != *..* ]] || die "$LOCK: invalid path $path"
  mkdir -p "$DEST/$(dirname "$path")"
  cp "$SRC/$path" "$DEST/$path"
  chmod 0644 "$DEST/$path"
  matches "$DEST/$path" "$sha" "$size" || die "$path: copy does not match $LOCK"
  count=$((count + 1))
  bytes=$((bytes + size))
done < <(entries)
(( count > 0 )) || die "$LOCK lists no files"
cp "$LOCK" "$DEST/firmware.lock"
chmod 0644 "$DEST/firmware.lock"

tag="$(awk '$1 == "tag" { print $2; exit }' "$LOCK")"
commit="$(awk '$1 == "commit" { print $2; exit }' "$LOCK")"
echo "bundle-firmware: $count files, $bytes bytes, linux-firmware $tag ($commit), verified -> $DEST"
