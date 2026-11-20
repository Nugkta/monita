#!/bin/sh
# Build the macOS icon from the approved 1024px master using system tools.
set -eu
if [ "$#" -ne 1 ]; then
  printf '%s\n' 'Usage: sh task-island/make-icon.sh OUTPUT.icns' >&2
  exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_png="$script_dir/assets/AppIcon.png"
output=$1
icon_tmp=$(mktemp -d "${TMPDIR:-/tmp}/monita-icon.XXXXXX")
trap 'rm -rf "$icon_tmp"' 0 1 2 3 15
iconset="$icon_tmp/AppIcon.iconset"
mkdir -p "$iconset" "$(dirname -- "$output")"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_png" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  pixels=$((size * 2))
  sips -z "$pixels" "$pixels" "$source_png" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$output"
