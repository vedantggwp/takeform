# HyperFrames comparison adapter

This arm builds a static browser ESM bundle from the shared `frameState` output. It does not reproduce edit timing: each captured frame selects the shared state for its rational timestamp. The generated root is a documented HyperFrames composition (`data-composition-id`, `data-width`, `data-height`, `data-duration`) and declares `data-no-timeline` because it is driven by frame state rather than a GSAP timeline.

`@hyperframes/producer` 0.8.39 is loaded from the caller-provided pinned runtime. The adapter uses `createRenderJob` and `executeRenderJob` with one worker, an explicit streaming configuration and the approved browser launcher. The producer's installed `pollHfReady` implementation requires `window.__hf = {duration, seek}`; `composition.mjs` supplies that exact page contract and returns an awaitable seek-completion promise for video layers.

Run the unit contract check with the frozen fixture root supplied by the coordinator:

```sh
FIXTURE_ROOT=... node --test comparisons/hyperframes/adapter.test.mjs
```

## T/L source support

`fixture-support.mjs` is separate from the validated M builder. It exposes only shared `frameState` observations: T caption ranges, speech source-time/rate and its muted picture sound; L's `24000/1001` rate, chapter labels, all 14 two-handle crossfades and continuous audio. It also produces declarative audio-track input for a later T/L composition builder. T's linear-dB values use a pinned-producer `data-fx-chain` gain node with `data-automation` targeting `fx.hf-gain.gain`; L's linear gain uses the producer's `volume` lane. The plan retains the source rational values next to those attributes.

This is based on pinned `@hyperframes/producer` 0.8.39 source: `parseAudioElements` reads `data-start`, `data-end`, `data-media-start`, `data-playback-rate`, `data-fx-chain` and `data-automation`; `resolveAutomation` accepts `fx.<nodeId>.<param>` targets; and `applyAudioFxChain` applies that gain automation to samples. The same source rejects imperative media `play`, `pause`, `currentTime` and `muted` assignments. No T or L browser bundle or render is created until M's cancellation/restart gates and a heavy lease are granted.

Future attempts record the shared-media semantic `manifestDigest`, the raw manifest-file SHA-256, and each selected `sourceId` to derivative SHA-256 mapping. The two manifest fingerprints have different meanings and are never compared. The historical `m-cold-4` receipt predates this field and retains neither fingerprint.

## M capability receipt

`m-cold-3` used the full 1920x1080, 30 fps, 480-frame M plan and selected the SDK's streaming screenshot route. It captured all 480 frames but strict completion failed without an MP4 because Chrome could not load `lp-mismatch.heic` and `station.heic` as image resources. `lp-matched.mov` is correctly treated as a video after the source-kind fix.

The frozen source bytes remain authoritative. A shared media-preparation proposal is required before any further renderer attempt: decode only the failing HEIC originals with Apple ImageIO, bake their EXIF orientation into pixel coordinates, preserve the decoded ICC color space and alpha, and write deterministic PNG derivatives outside frozen fixtures. A derivative manifest must bind each source ID to its original SHA-256, ImageIO and macOS versions, orientation, source and output dimensions, alpha state, input/output ICC hashes, command/settings digest and derivative SHA-256. Both renderer arms must consume exactly that manifest; neither may replace a fixture source or claim the derivative bytes are original media.
