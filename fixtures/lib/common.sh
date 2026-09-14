#!/usr/bin/env bash
set -euo pipefail

FIXTURES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_swift() {
  local src="$1"
  shift
  xcrun swift "$src" "$@"
}

write_label_png() {
  local text="$1"
  local path="$2"
  run_swift "$FIXTURES_ROOT/tools/LabelStill.swift" --output "$path" --text "$text" --bg "000000" --transparent
}
