#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
MEDIA="$ROOT/L/media"
rm -rf "$MEDIA"
mkdir -p "$MEDIA"

make_chapter() {
  local n="$1"
  local freq=$((180 + n * 17))
  local label
  label=$(printf "Chapter %02d repeated test material" "$n")
  local png="$MEDIA/$(printf 'chapter-%02d-label.png' "$n")"
  write_label_png "$label" "$png"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001" \
    -f lavfi -i "sine=frequency=${freq}:sample_rate=48000" \
    -i "$png" \
    -filter_complex "[0:v][2:v]overlay=0:0:format=auto" \
    -frames:v 2925 \
    -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p \
    -c:a aac -ar 48000 -ac 2 -shortest \
    "$MEDIA/$(printf 'chapter-%02d.mp4' "$n")"
  rm -f "$png"
}

for n in $(seq 1 15); do
  make_chapter "$n" &
  if (( n % 4 == 0 )); then
    wait
  fi
done
wait

node "$ROOT/lib/stamp-hashes.mjs" "$ROOT/L"
echo "L generate done"
