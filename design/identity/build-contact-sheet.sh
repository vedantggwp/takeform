#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source="$root/takeform-app-icon.svg"
out="$root/exports"
tmp="$out/.contact-sheet"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

command -v magick >/dev/null || { echo "magick is required" >&2; exit 1; }

for size in 16 24 32 64 128; do
  magick -background none "$source" -resize "${size}x${size}" -strip -depth 8 -define png:color-type=6 "$tmp/${size}.png"
done

# The five icons below retain their named pixel dimensions; only surrounding whitespace is enlarged.
magick \
  \( "$tmp/16.png" -background '#F4F2EC' -alpha remove -alpha off -gravity center -extent 96x160 \) \
  \( "$tmp/24.png" -background '#F4F2EC' -alpha remove -alpha off -gravity center -extent 96x160 \) \
  \( "$tmp/32.png" -background '#F4F2EC' -alpha remove -alpha off -gravity center -extent 96x160 \) \
  \( "$tmp/64.png" -background '#F4F2EC' -alpha remove -alpha off -gravity center -extent 120x160 \) \
  \( "$tmp/128.png" -background '#F4F2EC' -alpha remove -alpha off -gravity center -extent 152x160 \) \
  +append -background '#F4F2EC' -gravity center -extent 560x220 -strip -depth 8 -define png:color-type=2 "$out/contact-sheet-actual-size.png"
echo "Wrote $out/contact-sheet-actual-size.png"
