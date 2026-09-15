# HyperFrames Player bundle

This entry builds the interactive M comparison page for the accepted Native Preview Host. It is a static local bundle, not a producer export or a native acceptance result.

The builder freezes the accepted M snapshot, derives every layer and media target from shared `frameState`, validates the reviewed shared derivative manifest, and copies only selected assets under the host’s granted bundle root. It copies the exact nested `@hyperframes/player` and `@hyperframes/core` 0.8.39 browser files from the approved runtime. It does not load a CDN, GSAP, a compatibility shim, or a Player/Core private global.

The bundle uses Player’s public `seek`, `play`, and `pause` methods. Its native bridge preserves command request, session, and snapshot identities. A seek/load acknowledgement is `decoded` only after the Player’s composition document exposes every active video at the requested source time with current video data; it remains browser decode evidence, not native-renderer output evidence.

The host allowlist serves video under `.mp4` or `.webm`. Accepted H.264 MOV sources are copied byte-for-byte under a `.mp4` bundle path so the existing helper can serve them with its video MIME route. `bundle-manifest.json` retains the original hash and both source and served extensions. No media bytes, source times, or retime factors change.

## Build

```sh
/opt/homebrew/opt/node@22/bin/node comparisons/hyperframes/player/player.mjs \
  --bundle-root BUNDLE_ROOT \
  --fixture-root FIXTURE_ROOT \
  --derivative-root DERIVATIVE_ROOT \
  --media-prep-manifest DERIVATIVE_ROOT/manifest.json \
  --media-prep-module comparisons/media-prep/media-prep.mjs \
  --runtime RUNTIME_ROOT
```

The selected native host serves `BUNDLE_ROOT` at `/bundle/`; therefore `index.html` is written directly inside `BUNDLE_ROOT`.

## Test

```sh
TAKEFORM_FIXTURE_ROOT=FIXTURE_ROOT \
TAKEFORM_RUNTIME=RUNTIME_ROOT \
TAKEFORM_DERIVATIVE_ROOT=DERIVATIVE_ROOT \
TAKEFORM_MEDIA_PREP_MANIFEST=DERIVATIVE_ROOT/manifest.json \
TAKEFORM_MEDIA_PREP_MODULE=comparisons/media-prep/media-prep.mjs \
/opt/homebrew/opt/node@22/bin/node --test comparisons/hyperframes/player/player.test.mjs
```

Pinned Core 0.8.39 was observed to drive ordinary CSS animation through public Player seek in a local browser probe. Its 0.8.39 quickstart documents GSAP timelines rather than CSS/WAAPI composition authoring, so the CSS route is a pinned-runtime compatibility decision. Native WKWebView acceptance remains open while its driver is blocked.
