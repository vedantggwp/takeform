#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source="$root/takeform-app-icon.svg"
out="$root/exports"
iconset="$out/Takeform.iconset"

command -v magick >/dev/null || { echo "magick is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

rm -rf "$iconset" "$out/Takeform.icns"
mkdir -p "$iconset"

render() {
  name=$1
  pixels=$2
  magick -background none "$source" -resize "${pixels}x${pixels}" -strip -depth 8 -define png:color-type=6 "$iconset/$name"
}

render icon_16x16.png 16
render icon_16x16@2x.png 32
render icon_32x32.png 32
render icon_32x32@2x.png 64
render icon_64x64.png 64
render icon_64x64@2x.png 128
render icon_128x128.png 128
render icon_128x128@2x.png 256
render icon_256x256.png 256
render icon_256x256@2x.png 512
render icon_512x512.png 512
render icon_512x512@2x.png 1024

python3 "$root/pack-icns.py" "$iconset" "$out/Takeform.icns"
