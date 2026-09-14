#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
start=$(python3 -c 'import time; print(time.time())')
"$ROOT/M/generate.sh"
"$ROOT/T/generate.sh"
"$ROOT/L/generate.sh"
end=$(python3 -c 'import time; print(time.time())')
python3 -c "print('generation_wall_seconds=%.3f' % ($end - $start))"
du -sh "$ROOT/M/media" "$ROOT/T/media" "$ROOT/L/media"
