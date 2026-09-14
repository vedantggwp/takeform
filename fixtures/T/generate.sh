#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
MEDIA="$ROOT/T/media"
reuse_audio=false
if [[ "${1:-}" == "--reuse-audio" ]]; then
  reuse_audio=true
elif [[ $# -ne 0 ]]; then
  echo "usage: generate.sh [--reuse-audio]" >&2
  exit 2
fi

if [[ "$reuse_audio" == false ]]; then
  CTC_PYTHON="${CTC_PYTHON:?set CTC_PYTHON to a Python 3.12+ environment with fixtures/tools/requirements-ctc.txt installed}"
  CTC_MODEL_DIR="${CTC_MODEL_DIR:?set CTC_MODEL_DIR to the directory containing the pinned local Wav2Vec2 checkpoint}"
  rm -rf "$MEDIA"
  mkdir -p "$MEDIA"
  run_swift "$ROOT/tools/SpeechWriter.swift" \
    --text-file "$ROOT/T/script-take1.txt" \
    --output-aiff "$MEDIA/take1-speech.aiff" \
    --output-audio-receipt "$ROOT/T/audio-take1.json"
  run_swift "$ROOT/tools/SpeechWriter.swift" \
    --text-file "$ROOT/T/script-take2.txt" \
    --output-aiff "$MEDIA/take2-speech.aiff" \
    --output-audio-receipt "$ROOT/T/audio-take2.json"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tools/align_fixture_speech.py" --fixture "$ROOT/T" --source take1 --python "$CTC_PYTHON" --model-dir "$CTC_MODEL_DIR"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tools/align_fixture_speech.py" --fixture "$ROOT/T" --source take2 --python "$CTC_PYTHON" --model-dir "$CTC_MODEL_DIR"
else
  for required in "$MEDIA/take1-speech.aiff" "$MEDIA/take2-speech.aiff" "$ROOT/T/audio-take1.json" "$ROOT/T/audio-take2.json" "$ROOT/T/words-take1.json" "$ROOT/T/words-take2.json"; do
    [[ -f "$required" ]] || { echo "--reuse-audio requires $required" >&2; exit 1; }
  done
fi

pad_audio() {
  local in="$1" out="$2"
  ffmpeg -hide_banner -loglevel error -y -i "$in" \
    -af "apad=whole_dur=60" -t 60 "$out"
}

pad_audio "$MEDIA/take1-speech.aiff" "$MEDIA/take1-speech-60.aiff"
pad_audio "$MEDIA/take2-speech.aiff" "$MEDIA/take2-speech-60.aiff"

encode_take() {
  local speech="$1" label="$2" out="$3"
  local png="${out}.label.png"
  write_label_png "$label" "$png"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=60" \
    -i "$speech" \
    -i "$png" \
    -filter_complex "[0:v][2:v]overlay=0:0:format=auto" \
    -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p \
    -c:a aac -ar 48000 -ac 1 -shortest \
    "$out"
  rm -f "$png"
}

encode_take "$MEDIA/take1-speech-60.aiff" "Take 1 talking head stand-in" "$MEDIA/take1.mp4"
encode_take "$MEDIA/take2-speech-60.aiff" "Take 2 talking head stand-in" "$MEDIA/take2-cfr.mp4"

tmpdir=$(mktemp -d)
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/take2-cfr.mp4" -t 20 -an \
  -filter:v "fps=24,setpts=PTS-STARTPTS" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  "$tmpdir/seg24.mp4"
ffmpeg -hide_banner -loglevel error -y -ss 20 -t 20 -i "$MEDIA/take2-cfr.mp4" -an \
  -filter:v "fps=30,setpts=PTS-STARTPTS" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  "$tmpdir/seg30.mp4"
ffmpeg -hide_banner -loglevel error -y -ss 40 -t 20 -i "$MEDIA/take2-cfr.mp4" -an \
  -filter:v "fps=60,setpts=PTS-STARTPTS" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  "$tmpdir/seg60.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$tmpdir/seg24.mp4" -c copy -f mpegts "$tmpdir/seg24.ts"
ffmpeg -hide_banner -loglevel error -y -i "$tmpdir/seg30.mp4" -c copy -f mpegts "$tmpdir/seg30.ts"
ffmpeg -hide_banner -loglevel error -y -i "$tmpdir/seg60.mp4" -c copy -f mpegts "$tmpdir/seg60.ts"
cat "$tmpdir/seg24.ts" "$tmpdir/seg30.ts" "$tmpdir/seg60.ts" > "$tmpdir/all.ts"
ffmpeg -hide_banner -loglevel error -y -fflags +genpts -i "$tmpdir/all.ts" -c copy "$tmpdir/take2-v.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$tmpdir/take2-v.mp4" -i "$MEDIA/take2-speech-60.aiff" \
  -c:v copy -c:a aac -ar 48000 -ac 1 -shortest \
  "$MEDIA/take2.mp4"
rm -rf "$tmpdir" "$MEDIA/take2-cfr.mp4" "$MEDIA/take1-speech-60.aiff" "$MEDIA/take2-speech-60.aiff"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=110:sample_rate=48000:duration=90" \
  -af "volume=-18dB" -c:a aac -ar 48000 -ac 2 "$MEDIA/music.m4a"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=0.4" \
  -af "volume=-6dB" -c:a aac -ar 48000 -ac 2 "$MEDIA/sfx.m4a"

node "$ROOT/lib/stamp-t-expected.mjs" "$ROOT/T"
node "$ROOT/lib/stamp-hashes.mjs" "$ROOT/T"
echo "T generate done"
