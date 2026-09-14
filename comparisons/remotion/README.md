# Remotion comparison adapter

This adapter is source preparation for issue #25. It consumes a frozen shared snapshot and calls `frameState` for every composition frame. It does not recreate cuts, source time, retime, captions or crossfades.

`asset-server.mjs` grants only selected snapshot sources from a caller-provided fixture root. It uses one loopback origin, byte ranges and source IDs. It does not copy fixture media or allow a file URL, remote asset or unlisted path.

`render-attempt.mjs` will use the reviewed runtime's public `bundle()` and `renderMedia()` APIs. It converts rational FPS to a number only at Remotion's API boundary. It requires explicit streaming reserve inputs and uses one render worker with the accepted browser wrapper in `chrome-for-testing` mode. Remotion's public `renderMedia()` options do not accept a caller-owned browser profile directory. That profile-ownership question remains a prerequisite for a heavy attempt.

## Source checks

```sh
/opt/homebrew/opt/node@22/bin/node --test ./test/asset-server.test.mjs
```

The dependency PR is required before a compilation or render attempt. No browser, composition bundle, fixture export, performance measurement or native preview is claimed by this source-only stage.
