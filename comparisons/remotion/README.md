# Remotion comparison adapter

This adapter is source preparation and bounded M execution evidence for issue #25. It consumes a frozen shared snapshot and calls `frameState` for every composition frame. It does not recreate cuts, source time, retime, captions or crossfades.

`asset-server.mjs` grants only selected snapshot sources from a caller-provided fixture root. It uses one loopback origin, byte ranges and source IDs. It does not copy fixture media or allow a file URL, remote asset or unlisted path. For M, a caller may pass the exact `validateManifest()` result from `comparisons/media-prep/media-prep.mjs` with its explicit derivative root; the server then substitutes only those validated source IDs and retains the snapshot's original source identities.

`render-attempt.mjs` uses the reviewed runtime's public `bundle()`, `getCompositions()`, `selectComposition()` and `renderMedia()` APIs. It converts rational FPS to a number only at Remotion's API boundary. It requires explicit streaming reserve inputs and uses one render worker with the accepted browser wrapper in `chrome-for-testing` mode. A caller must launch every render candidate in an attempt-owned Node child with `TMPDIR` set to that attempt's `tmp` directory before this module imports either SDK. The adapter rejects any other `TMPDIR`. Pinned Remotion creates its internal browser profile under `os.tmpdir()` and deletes it on browser close or process exit.

`captureDiagnosticStill()` is a bounded public-renderer proof for one selected frame. Its output is fixed to `diagnostic.png` under the attempt root; it is not a substitute for a canonical render attempt. A caller must retain each diagnostic's source mapping, raw PNG and decoded-RGBA hashes, bundle fingerprint, browser target/version, terminal receipt, and cleanup inventory.

## M execution boundary

Three raw M H.264 exports completed at 1920×1080, 30 fps and 480 frames (16 seconds), using Remotion 4.0.524, the accepted fixture snapshot, accepted prepared-media manifest, explicit Chrome target and an owned `TMPDIR`. Their wall times were 41.244 s, 40.018 s and 40.825 s; the median was 40.825 s. They meet the fixture's fixed 3× realtime export threshold (48 s for this 16-second program). The fixture supplies no cache-state protocol, so these are not cold/warm benchmark results.

Public cancellation was exercised after 10 rendered frames with no encoded output. The renderer reported interruption and the launcher exited 1. A post-cancel profile inventory raced Chrome removing a profile file, so cleanup was completed manually from the valid interrupted terminal receipt and was limited to task-owned scratch. This is a lifecycle limitation, not an automatic-cleanup success claim.

The fixture's pre-agreed `first-last-frame-hash-stable` predicate currently **fails**: first decoded RGBA hashes matched across the three outputs while final decoded RGBA hashes differed. Independent review found no visible discrepancy at sampled frames, but that does not identify an encoder cause or make the determinism predicate pass. All three divergent MP4s are retained while a bounded lossless still diagnostic is assessed. See [REPORT.md](./REPORT.md) for output hashes, scope and evidence gaps.

## Source checks

```sh
/opt/homebrew/opt/node@22/bin/node --test ./test/*.test.mjs
```

The dependency PR is required before a compilation or render attempt. This adapter does not claim native preview acceptance, full-film visual acceptance, audio listening acceptance, or a resolved determinism cause.
