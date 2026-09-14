#!/bin/bash
# Assemble "Takeform Proof.app" from the release build, sign it inside out with an ad-hoc identity,
# and record the signing facts. VARIANT=default signs with no entitlements; VARIANT=sandbox applies bundle/sandbox/*.entitlements.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VARIANT="${1:-default}"
BIN="$ROOT/.build/release"
APP="$ROOT/.build/bundle/Takeform Proof.app"
R="${RECEIPTS_DIR:-$ROOT/receipts}"
mkdir -p "$R"
redact() { sed -e "s#$HOME#\$HOME#g"; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
cp "$ROOT/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/bundle/com.takeform.proof.agent.plist" "$APP/Contents/Library/LaunchAgents/"
for b in ProofApp ProofService ProofHelper proofctl; do cp "$BIN/$b" "$APP/Contents/MacOS/$b"; done

sign() {
  local target="$1" ident="$2" ent="${3:-}"
  if [ -n "$ent" ] && [ "$VARIANT" = sandbox ]; then
    codesign -f -s - --options runtime --identifier "$ident" --entitlements "$ROOT/bundle/sandbox/$ent" "$target"
  else
    codesign -f -s - --options runtime --identifier "$ident" "$target"
  fi
}
sign "$APP/Contents/MacOS/ProofHelper" com.takeform.proof.helper service.entitlements
sign "$APP/Contents/MacOS/proofctl" com.takeform.proof.cli
sign "$APP/Contents/MacOS/ProofService" com.takeform.proof.service service.entitlements
sign "$APP" com.takeform.proof.app app.entitlements

{
  echo "variant: $VARIANT"
  for b in ProofHelper proofctl ProofService; do
    echo "=== $b"
    codesign -dvvv --entitlements :- "$APP/Contents/MacOS/$b" 2>&1
  done
  echo "=== Takeform Proof.app"
  codesign -dvvv --entitlements :- "$APP" 2>&1
} | redact > "$R/codesign-$VARIANT.txt"

{
  echo "\$ codesign --verify --deep --strict --verbose=2"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 && echo "verify exit 0" || echo "verify exit $?"
  echo
  echo "\$ spctl -a -vv"
  spctl -a -vv "$APP" 2>&1 && echo "spctl exit 0" || echo "spctl exit $?"
  echo
  echo "\$ du -sk"
  du -sk "$APP" 2>&1
  echo
  echo "\$ find bundle"
  find "$APP" -type f | sort
} | redact > "$R/bundle-verify-$VARIANT.txt"
echo "bundle at $APP ($VARIANT)"
