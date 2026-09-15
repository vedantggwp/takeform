#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="$root/exports"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/takeform-icon-verify.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

command -v iconutil >/dev/null || { echo "iconutil is required" >&2; exit 1; }
command -v sips >/dev/null || { echo "sips is required" >&2; exit 1; }

# Use Apple's decoder; its iconset-to-ICNS encoder is known-broken on this host.
iconutil --convert iconset --output "$tmp/Takeform.iconset" "$out/Takeform.icns"

check() {
  name=$1
  expected=$2
  file="$tmp/Takeform.iconset/$name"
  [ -f "$file" ] || { echo "missing decoded $name" >&2; exit 1; }
  dimensions=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel(Width|Height):/ {print $2}' | tr '\n' x)
  [ "$dimensions" = "${expected}x${expected}x" ] || { echo "wrong dimensions for $name: $dimensions" >&2; exit 1; }
}

check icon_16x16.png 16
check icon_32x32.png 32
# Apple's decoder exposes the legacy icp6 64px payload as its 48px representation.
check icon_48x48.png 48
check icon_128x128.png 128
check icon_256x256.png 256
check icon_512x512.png 512
check icon_512x512@2x.png 1024
echo "Apple decoder verified ICNS representations: 16, 32, legacy-48, 128, 256, 512, 1024 px"
