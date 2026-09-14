#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$ROOT/schema/fixture-manifest.schema.json"
MEAS="$ROOT/schema/measurement-result.schema.json"
VAL=(node "$ROOT/lib/validate-schema.mjs")

"${VAL[@]}" "$SCHEMA" "$ROOT/M/manifest.json"
"${VAL[@]}" "$SCHEMA" "$ROOT/T/manifest.json"
"${VAL[@]}" "$SCHEMA" "$ROOT/L/manifest.json"
"${VAL[@]}" --expect-fail "$SCHEMA" "$ROOT/negative/malformed-manifest.json"

if [[ -f "$ROOT/measurement-result.example.json" ]]; then
  "${VAL[@]}" "$MEAS" "$ROOT/measurement-result.example.json"
fi

node "$ROOT/lib/verify-t-contract.mjs" "$ROOT/T"
node "$ROOT/tests/verify-t-contract-regression.mjs" "$ROOT/T"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/ctc-text-regression.py"

python3 - << PY
import json, subprocess, sys
from pathlib import Path
root = Path("$ROOT")

def load(p):
    return json.loads(Path(p).read_text())

def check_hashes(fx):
    d = root / fx
    h = load(d / "hashes.json")
    kind = h.get("hashKind", "container")
    missing = []
    mismatch = []
    for rel, rec in h["files"].items():
        p = d / rel
        if not p.exists():
            missing.append(rel)
            continue
        out = subprocess.check_output(["shasum", "-a", "256", str(p)], text=True).split()[0]
        if kind == "container" and out != rec["sha256"]:
            mismatch.append(rel)
    if missing or mismatch:
        raise SystemExit(f"{fx} hash check failed missing={missing} mismatch={mismatch}")
    print(f"ok hashes {fx} kind={kind} files={len(h['files'])}")

def check_plan_math(fx):
    m = load(root / fx / "manifest.json")
    exp = m["expected"]
    rate = m["canonicalPlan"]["outputFrameRate"]
    dur = exp["outputDuration"]
    seconds = dur["ticks"] / dur["timescale"]
    fps = rate["num"] / rate["den"]
    if fx == "M":
        assert exp["frameCount"] == 480, exp["frameCount"]
        assert abs(seconds - 16) < 1e-9
        assert abs(fps - 30) < 1e-9
    if fx == "T":
        assert exp["frameCount"] == 2700
        assert abs(seconds - 90) < 1e-9
    if fx == "L":
        assert exp["frameCount"] == 43157
        # 43157 frames at 24000/1001
        assert dur["ticks"] == 43157 * 1001
        assert dur["timescale"] == 24000
    used = {row["momentId"]: row["usedCount"] for row in exp["noRepeatCoverage"]}
    for mid, count in used.items():
        assert count == 1, (fx, mid, count)
    print(f"ok arithmetic {fx} frames={exp['frameCount']}")

def probe(path):
    out = subprocess.check_output([
        "ffprobe", "-hide_banner", "-loglevel", "error",
        "-print_format", "json", "-show_format", "-show_streams", str(path)
    ], text=True)
    return json.loads(out)

def check_probe(fx):
    m = load(root / fx / "manifest.json")
    for src in m["sources"]:
        p = root / fx / src["path"]
        if src["kind"] == "corrupt":
            assert p.exists() and p.stat().st_size < 1024
            continue
        if src["kind"] in ("still", "livePhotoStill", "duplicateOf"):
            assert p.exists(), src["path"]
            continue
        info = probe(p)
        fmt = info.get("format", {})
        duration = float(fmt.get("duration", "0") or 0)
        if src.get("duration") and src["kind"] in ("video", "audio"):
            expected = src["duration"]["ticks"] / src["duration"]["timescale"]
            if expected > 0 and abs(duration - expected) > 0.35:
                raise SystemExit(f"{fx} {src['id']} duration {duration} != {expected}")
        if src["id"] == "take2":
            streams = [s for s in info["streams"] if s.get("codec_type") == "video"]
            if streams:
                avg = streams[0].get("avg_frame_rate", "0/0")
                r = streams[0].get("r_frame_rate", "0/0")
                print(f"ok VFR probe take2 avg_frame_rate={avg} r_frame_rate={r}")
    print(f"ok probe {fx}")

for fx in ("M", "T", "L"):
    check_plan_math(fx)
    if (root / fx / "hashes.json").exists():
        check_hashes(fx)
        check_probe(fx)
    else:
        print(f"skip hashes/probe {fx}: hashes.json not present yet")

print("verify ok")
PY

"$ROOT/hygiene-check.sh"
echo "verify.sh finished"
