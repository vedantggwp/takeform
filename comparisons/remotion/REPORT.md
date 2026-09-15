# Remotion M execution report

This report records bounded M execution for PR40. It does not select a renderer, accept native preview, establish full-film visual or audio quality, certify a cold/warm benchmark, or resolve the output mismatch.

## Raw M exports

Each completed export requested M at 1920×1080, 30 fps and 480 frames (16 seconds), with adapter `3a48b0cc4b9ae3ca120019bcd65df7e6e0a6acf5`, pinned Remotion 4.0.524, explicit Chrome target, owned `TMPDIR`, accepted fixture commit `8a3daf1978093a3d67649b8f3779a9aa15fab876`, prepared-media semantic manifest digest `4e5d53220b111089aff3d6c5062e0f07ebe7998b43270215aef5a174d90809a4`, and raw manifest-file SHA-256 `9af9210efe48f33ba2aff5b4ef34f161a6b06141f4e7846fcc0ac79beb9e5e69`.

| Attempt | Wall time | Renderer time | MP4 SHA-256 |
|---|---:|---:|---|
| `m-20260915t0056z` | 41.244 s | 33.791 s | `eb74eb6b013b33312f40a8a901ab4ceed4d3e8291d3dbf04b2c3bcec24f153dc` |
| `m-restart-public-1` | 40.018 s | 33.435 s | `dd3397df9c24cb8068965a3a2baa9a6793afeba8fa8dcd062668200c373a61ce` |
| `m-raw-public-3` | 40.825 s | 33.631 s | `d50bd239b3c88e03a93d15d699732dd0a4356fdd42dd6831a077afe98da7da06` |

The median raw wall time is 40.825 seconds. The fixture's `export-wall-realtime-multiple` limit is 3× realtime, or 48 seconds for 16 seconds of output; all three raw measurements meet it. The fixture does not specify cache state, so the results are not a cold/warm benchmark.

## Lifecycle evidence

`m-cancel-public-1` called the public `renderMedia` cancel callback after 10 rendered frames and before encoding. It recorded interrupted status, no output and launcher exit 1. Chrome removed a profile file during the immediate post-cancel inventory; automatic cleanup therefore did not run. The valid interrupted terminal receipt then constrained manual cleanup to that attempt's own bundle and temporary-profile paths. This limitation remains disclosed.

## Determinism failure

The fixture defines `first-last-frame-hash-stable` as identical first and last decoded-frame hashes across two renders on one machine. The first decoded RGBA hash was the same in all three runs, but final hashes differed (`0ae049…`, `c36bd8…`, `f9be9b…`). The predicate therefore **fails**. Independent inspection saw no visible sampled content, timing or layout discrepancy, which does not establish an encoding explanation. The three outputs remain retained for the lossless still investigation.

The first two successful attempts cleaned their transient bundle directories before a tree fingerprint was retained. The third recorded bundle-tree SHA-256 `e416cefc0bea0c5fb9cfa95a86e97536ac2f2330cdfebfc0a0f135f229b1e294`; the earlier evidence gap is preserved rather than reconstructed.
