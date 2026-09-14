#!/usr/bin/env bash
set -euo pipefail

PINNED_SHA="6d7c49b2d03ca035704535a6ed5b5533ee1c8c19"
REPO_URL="https://github.com/heygen-com/hyperframes-gemini-agent.git"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hf-customize-probe.XXXXXX")"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "pinned_sha: $PINNED_SHA"
echo "python3: $(python3 --version 2>&1)"
echo "git: $(git --version)"
echo "uname: $(uname -srm)"

git clone --quiet "$REPO_URL" "$WORKDIR/upstream"
if ! git -C "$WORKDIR/upstream" cat-file -e "${PINNED_SHA}^{commit}"; then
  echo "pinned sha ${PINNED_SHA} is absent from the clone" >&2
  exit 1
fi
git -C "$WORKDIR/upstream" checkout --quiet "$PINNED_SHA"

COMPOSE_DIR="$WORKDIR/composition"
mkdir -p "$COMPOSE_DIR"
cat > "$COMPOSE_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html data-composition-variables='[{"id":"count","type":"number","default":"wrong"}]'>
<head><title>probe</title></head>
<body></body>
</html>
HTML

printf '%s\n' '{}' > "$WORKDIR/empty.json"
printf '%s\n' '{"count":"wrong"}' > "$WORKDIR/explicit.json"

SCRIPT="$WORKDIR/upstream/workspace/scripts/customize.py"

echo "run_omitted_default:"
python3 "$SCRIPT" "$COMPOSE_DIR" "$WORKDIR/empty.json" "$WORKDIR/resolved-empty.json" >/dev/null
cat "$WORKDIR/resolved-empty.json"

echo "run_explicit_string:"
explicit_status=0
python3 "$SCRIPT" "$COMPOSE_DIR" "$WORKDIR/explicit.json" "$WORKDIR/resolved-explicit.json" \
  >/dev/null 2>"$WORKDIR/explicit.err" || explicit_status=$?
echo "exit_status: $explicit_status"
cat "$WORKDIR/explicit.err"
