#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
MEDIA="$ROOT/M/media"
ensure_dir() { rm -rf "$1"; mkdir -p "$1"; }
ensure_dir "$MEDIA"

still() {
  local name="$1" color="$2" label="$3" box="$4"
  run_swift "$ROOT/tools/LabelStill.swift" \
    --output "$MEDIA/${name}.png" --text "$label" --bg "${color#0x}" --box "$box"
}

still "harbor" "0x1a365d" "Harbor still" "200,700,900,120,4fd1c5"
still "workshop" "0x7c4a1e" "Workshop still" "240,640,1440,280,c4a574"
still "hill" "0x2f6b3a" "Hill still" "860,180,220,220,ffd166"
still "night" "0x0b1326" "Night window" "720,280,480,360,f4d35e"
still "market" "0x9b2226" "Market still" "160,200,1600,160,e9c46a"
still "library" "0x3d405b" "Library still" "300,120,80,840,e0e1dd"
still "garden" "0x52796f" "Garden still" "400,400,140,140,ef476f"

still "station" "0x22223b" "Station still" "0,820,1920,80,f2e9e4"
run_swift "$ROOT/tools/HeicWriter.swift" --input "$MEDIA/station.png" --output "$MEDIA/station.heic" --orientation 6
rm -f "$MEDIA/station.png"

encode_labeled_clip() {
  local out="$1" rate="$2" duration="$3" label="$4"
  local png="${out}.label.png"
  write_label_png "$label" "$png"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=${rate}:duration=${duration}" \
    -i "$png" \
    -filter_complex "[0:v][1:v]overlay=0:0:format=auto" \
    -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p \
    "$out"
  rm -f "$png"
}

encode_labeled_clip "$MEDIA/clip-24.mov" "24" "3" "24 fps moving clip"
encode_labeled_clip "$MEDIA/clip-2997.mp4" "30000/1001" "4" "29.97 fps moving clip"

make_lp() {
  local stem="$1" cid_still="$2" cid_video="$3" label="$4"
  encode_labeled_clip "$MEDIA/${stem}-raw.mov" "30" "3" "$label"
  run_swift "$ROOT/tools/ContentIdWriter.swift" \
    --input "$MEDIA/${stem}-raw.mov" --output "$MEDIA/${stem}.mov" --id "$cid_video"
  rm -f "$MEDIA/${stem}-raw.mov"
  ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/${stem}.mov" -frames:v 1 "$MEDIA/${stem}-still.png"
  run_swift "$ROOT/tools/HeicWriter.swift" \
    --input "$MEDIA/${stem}-still.png" --output "$MEDIA/${stem}.heic" --content-id "$cid_still"
  rm -f "$MEDIA/${stem}-still.png"
}

make_lp "lp-matched" "LP-MATCHED-001" "LP-MATCHED-001" "Live Photo matched"
make_lp "lp-mismatch" "LP-MISMATCH-STILL" "LP-MISMATCH-VIDEO" "Live Photo mismatch"

cp "$MEDIA/harbor.png" "$MEDIA/harbor-duplicate.png"
head -c 256 "$MEDIA/harbor.png" > "$MEDIA/harbor-corrupt.png"
printf 'TRUNCATED' >> "$MEDIA/harbor-corrupt.png"

node "$ROOT/lib/stamp-hashes.mjs" "$ROOT/M"
echo "M generate done"
