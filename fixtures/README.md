# How to regenerate and measure Takeform fixtures

These fixtures are renderer measurement inputs and edge cases. They are not accepted creator films. Issue 16 owns the acceptance films. Those films need meaningful speech, real visual content, an actual story, and source versus output checks at every speech cut.

Lip sync cannot be judged on synthesized speech without a face. That check is deferred to real footage under issue 16.

Generated media are never tracked in git. Generators and hashes are tracked. Media live under `fixtures/<id>/media/` and are ignored by git.

No renderer is chosen or run from this directory.

## What you get

The registry is `fixtures/registry.json`. It lists three fixtures.

- M is a 16 s overlapping montage at 30/1 fps and 1920x1080. It has twelve moments, a duplicate still, and a truncated corrupt file.
- T is an about 90 s talking-head edit. Take 1 has a repeated phrase and a two second pause. Take 2 is a VFR concatenation. Word times come from `AVSpeechSynthesizer` word-boundary callbacks.
- L is a 30 minute chaptered film at 24000/1001. It is fifteen labelled two-minute chapters of repeated test material, with a 24-frame crossfade on each join.

The data shapes are `fixtures/schema/fixture-manifest.schema.json` and `fixtures/schema/measurement-result.schema.json`. Times are `{ticks, timescale}` rationals. Source ranges and output ranges stay distinct objects.

## How to regenerate

Work on a Mac with the pinned tools recorded in each manifest `generator.toolPins`. Current pins are FFmpeg 8.0.1, Swift 6.3, Node 22.22.1, and macOS 26.6.2 (25G83) arm64. This FFmpeg build has no drawtext filter. Labels are PNG overlays from `LabelStill.swift` using the system UI font.

From the repository root:

```bash
./fixtures/generate.sh
./fixtures/verify.sh
```

`generate.sh` deletes each `media/` directory, writes new files, and stamps `hashes.json` plus source `sha256` fields in the manifests.

Speech is written to AIFF first, then transcoded. `say -o` with `.m4a` is not used.

## How to verify

`verify.sh` does the following.

1. Validates M, T, and L manifests against `fixture-manifest.schema.json`.
2. Validates that `negative/malformed-manifest.json` fails with a clear missing-field message.
3. Checks plan arithmetic (480, 2700, and 43157 frames).
4. Checks `hashes.json` against file bytes when hashes exist.
5. Probes generated media with ffprobe.
6. Confirms the talking-head word receipt names `AVSpeechSynthesizer` and is not human ground truth.
7. Runs `hygiene-check.sh`.

Run generate twice when you need the hash stability finding. Compare `hashes.json`. On this machine two consecutive runs matched container sha256 for every T and L file and for 14 of 16 M files. The two Live Photo MOV wrappers differed. Isolated ContentIdWriter copies of one encode matched. The MOV difference is the x264 encode of those clips. For those two files, compare decoded video with `ffmpeg -map 0:v -f md5`. Talking-head word-boundary receipts can jitter by tens of milliseconds across runs even when the AIFF bytes match. Same machine, same pins is the only identity claim. Cross-machine byte identity is not promised.

## How to read a manifest

Each manifest has `sources`, `moments`, `canonicalPlan`, `expected`, `rights`, and `thresholds`.

A Live Photo pair is one moment. The no-repeat table keys on moments, not files. The mismatched Live Photo pair is still one moment, with `confidencePermille` 200.

Fixture L frame count uses this rule. Planned exclusive end is 1800 s. Frame `i` presents at `i * 1001/24000` s. Frames with PTS in `[0, 1800)` are `i = 0` through `43156`, so the count is 43157. That is `floor((1800 * 24000 - 1) / 1001) + 1`. Fourteen chapters contribute 2877 frames. Chapter 15 contributes 2879 frames. Source files include 24-frame handles on each side so a join crossfade does not consume display length.

## How to run the protocol

Use one machine, one OS build, and the pinned tools. Take three runs per measurement. Report the median. Keep the raw numbers. Separate cold and warm. Record every failed run.

Selective invalidation is a different check from segment render reuse. Reuse across a join needs transition handles, matching codec and timebase, and sample continuity.

Required negative cases and expected outcomes live in `fixtures/negative/cases.json`.

- A malformed manifest fails schema validation and does not start a render.
- An unsupported feature is refused before render.
- Missing media is a plan-time error that names the source.
- A stale preview cannot approve a newer plan digest.
- An interrupted L render reopens as exactly one interrupted attempt.

Never mark an unrun check as passed. Use `not_run`.

## How to fill a measurement result

Copy `fixtures/measurement-result.example.json`. Set `backend.identity`, versions, `runKind`, wall time, peak RSS, seek latencies, first preview frame time, output sha256, and per-check status. Allowed statuses are `pass`, `fail`, `not_run`, and `needs_human_viewing`.

Human viewing or listening is required for montage scene identity, talking-head speech cuts, and long-film chapter joins. Lip sync on these synthesized takes is not a pass or fail here.

## Rights

Every source is generated on the machine that runs `generate.sh`. Generators and manifests are MIT. Synthesized speech from macOS voices is unverified for redistribution. That is why media bytes are not tracked.

## Thresholds

These limits were written before any renderer measurement.

| Check | Fixture | Limit | Human |
| --- | --- | --- | --- |
| Export wall time | M | 3x realtime | no |
| Seek to frame 240 | M | 250 ms | no |
| First and last decoded frame hashes match across two same-machine renders | M | identical | no |
| Every moment used exactly once | M | 1 | no |
| Caption output range projects from a measured source range | T | true | no |
| Corrected word keeps timing | T | 1 ms | no |
| Word onset error median | T | 50 ms | no |
| Word onset error p95 | T | 120 ms | no |
| No caption straddles a cut | T | true | no |
| Audio peak | T | -1 dBTP | no |
| Integrated loudness error | T | 1 LU | no |
| Audio to video offset | T | 1 output frame | no |
| Listen through speech cuts | T | pass by ear | yes |
| Peak RSS | L | 4 GB | no |
| Export wall time | L | 2x realtime | no |
| Cancel at minute 10 | L | stop in 5 s, no partial receipt | no |
| Kill and reopen | L | one interrupted attempt | no |
| Chapter 7 change | L | re-render chapter 7 plus unclean adjacent boundaries | no |
| Joined output | L | one continuous stream, no dropped audio sample | no |
| Listen through chapter joins | L | pass by ear | yes |
| Local selection feedback p95 | all | 100 ms | no |

## Word timings

`fixtures/T/words-take1.json` and `words-take2.json` are synthesizer word-boundary receipts. They are not ground truth from a human. Do not invent even spacing for a phrase.
