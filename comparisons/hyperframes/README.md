# HyperFrames comparison adapter

This arm builds a static browser ESM bundle from the shared `frameState` output. It does not reproduce edit timing: each captured frame selects the shared state for its rational timestamp. The generated root is a documented HyperFrames composition (`data-composition-id`, `data-width`, `data-height`, `data-duration`) and declares `data-no-timeline` because it is driven by frame state rather than a GSAP timeline.

`@hyperframes/producer` 0.8.39 is loaded from the caller-provided pinned runtime. The adapter uses `createRenderJob` and `executeRenderJob` with one worker, an explicit streaming configuration and the approved browser launcher. The producer's installed `pollHfReady` implementation requires `window.__hf = {duration, seek}`; `composition.mjs` supplies that exact page contract and returns an awaitable seek-completion promise for video layers.

Run the unit contract check with the frozen fixture root supplied by the coordinator:

```sh
FIXTURE_ROOT=... DERIVATIVE_ROOT=... MEDIA_PREP_MANIFEST=... MEDIA_PREP_MODULE=... node --test comparisons/hyperframes/adapter.test.mjs
```

## T/L source support

`fixture-support.mjs` reads shared `frameState` for T caption ranges, speech source-time/rate and muted picture sound, plus L's `24000/1001` rate, chapter labels, 14 two-handle crossfades and continuous audio. `tl-composition.mjs` turns that state into T/L projects. It emits separate muted picture videos and timeline-tagged audio tracks, so picture audio cannot enter the producer mix twice. T's linear-dB values use a pinned-producer `data-fx-chain` gain node with `data-automation` targeting `fx.hf-gain.gain`; L's linear gain uses the producer's `volume` lane. The generated seek module applies only state-derived visual styles, captions and chapter labels, and waits for video seeks before capture.

This is based on pinned `@hyperframes/producer` 0.8.39 source: `parseAudioElements` reads `data-start`, `data-end`, `data-media-start`, `data-playback-rate`, `data-fx-chain` and `data-automation`; `resolveAutomation` accepts `fx.<nodeId>.<param>` targets; and `applyAudioFxChain` applies that gain automation to samples. The T/L test compiles emitted timing attributes through the public core compiler, discovers emitted video and audio through public engine parsers, and lints the composition through the public producer entrypoint. The separate M seek protocol uses imperative `currentTime` and `muted` assignments. T/L use the producer's declarative timing attributes for extracted media and separate audio mixing. No T or L render has run. Canonical output verification still waits for M's cancellation/restart gate and a heavy lease.

Future attempts record the shared-media semantic `manifestDigest`, the raw manifest-file SHA-256, and each selected `sourceId` to derivative SHA-256 mapping. The two manifest fingerprints have different meanings and are never compared. The historical `m-cold-4` receipt predates this field and retains neither fingerprint.

## M capability receipt

`m-cold-3` used the full 1920x1080, 30 fps, 480-frame M plan and selected the SDK's streaming screenshot route. It captured all 480 frames but strict completion failed without an MP4 because Chrome could not load `lp-mismatch.heic` and `station.heic` as image resources. `lp-matched.mov` is correctly treated as a video after the source-kind fix.

The frozen source bytes remain authoritative. A shared media-preparation proposal is required before any further renderer attempt: decode only the failing HEIC originals with Apple ImageIO, bake their EXIF orientation into pixel coordinates, preserve the decoded ICC color space and alpha, and write deterministic PNG derivatives outside frozen fixtures. A derivative manifest must bind each source ID to its original SHA-256, ImageIO and macOS versions, orientation, source and output dimensions, alpha state, input/output ICC hashes, command/settings digest and derivative SHA-256. Both renderer arms must consume exactly that manifest; neither may replace a fixture source or claim the derivative bytes are original media.
