#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="$root/exports/appearance-variants"
mkdir -p "$out"

command -v magick >/dev/null || { echo "magick is required" >&2; exit 1; }

render() {
  source=$1
  output=$2
  magick -background none "$root/$source" -resize 1024x1024 -strip -depth 8 -define png:color-type=6 "$out/$output"
}

render takeform-app-icon.svg Takeform-default-1024.png
render takeform-app-icon-dark.svg Takeform-dark-1024.png
render takeform-app-icon-mono.svg Takeform-mono-1024.png
echo "Wrote default, dark, and mono 1024px appearance exports"
