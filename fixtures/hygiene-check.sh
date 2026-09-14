#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp)
fail=0
while IFS= read -r -d '' f; do
  if rg -n \
    -e '/Users/[A-Za-z]' \
    -e '/home/[A-Za-z]' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'BEGIN (RSA |OPENSSH )?PRIVATE KEY' \
    -e '-----BEGIN' \
    -e 'api[_-]?key[[:space:]]*=' \
    "$f" >>"$tmp" 2>/dev/null; then
    fail=1
  fi
  if rg -n -e '\bVedant\b' "$f" >>"$tmp" 2>/dev/null; then
    fail=1
  fi
done < <(find "$ROOT" -type f ! -path '*/media/*' ! -name '*.aiff' ! -name 'hygiene-check.sh' -print0)

if [[ -s "$tmp" ]]; then
  echo "hygiene-check failed:"
  cat "$tmp"
  rm -f "$tmp"
  exit 1
fi
rm -f "$tmp"
echo "hygiene-check ok"
