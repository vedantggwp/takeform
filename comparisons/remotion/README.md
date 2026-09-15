# Remotion comparison adapter

This adapter is source preparation for issue #25. It consumes a frozen shared snapshot and calls `frameState` for every composition frame. It does not recreate cuts, source time, retime, captions or crossfades.

`asset-server.mjs` grants only selected snapshot sources from a caller-provided fixture root. It uses one loopback origin, byte ranges and source IDs. It does not copy fixture media or allow a file URL, remote asset or unlisted path. For M, a caller may pass the exact `validateManifest()` result from `comparisons/media-prep/media-prep.mjs` with its explicit derivative root; the server then substitutes only those validated source IDs and retains the snapshot's original source identities.

`render-attempt.mjs` uses the reviewed runtime's public `bundle()`, `getCompositions()`, `selectComposition()` and `renderMedia()` APIs. It converts rational FPS to a number only at Remotion's API boundary. It requires explicit streaming reserve inputs and uses one render worker with the accepted browser wrapper in `chrome-for-testing` mode. A caller must launch every render candidate in an attempt-owned Node child with `TMPDIR` set to that attempt's `tmp` directory before this module imports either SDK. The adapter rejects any other `TMPDIR`. Pinned Remotion creates its internal browser profile under `os.tmpdir()` and deletes it on browser close or process exit.

`captureDiagnosticStill()` is a bounded public-renderer proof for one selected frame. Its output is fixed to `diagnostic.png` under the attempt root; it is not a substitute for a canonical render attempt.

## Source checks

```sh
/opt/homebrew/opt/node@22/bin/node --test ./test/*.test.mjs
```

The dependency PR is required before a compilation or render attempt. No browser, composition bundle, fixture export, performance measurement or native preview is claimed by this source-only stage.
