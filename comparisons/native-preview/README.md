# Native preview host

This is a native comparison host for issue #26. It is a SwiftUI app with a `WKWebView`, typed frame commands and an app-owned Node loopback helper. It does not contain a renderer, choose a renderer or prove decoded source media.

The controlled session records a backend, snapshot identity, rational frame rate, frame bounds, requested frame, displayed frame and playback state. Native controls report the requested frame immediately, but update the displayed frame only after a valid page acknowledgement. The diagnostic page acknowledges after `requestAnimationFrame`. That demonstrates a web-paint callback only. It is not a decoded-frame or renderer output acknowledgement.

## Developer build

```sh
./script/build_app.sh
```

The script creates an ad-hoc signed app at `.build/bundle/Takeform Native Preview.app`. It copies the SwiftPM resource bundle, including the Node helper and diagnostic page, then checks the copied resource locations. It does not launch the app.

Node is an explicit developer dependency. On launch, set `TAKEFORM_NODE` through the developer launch environment or select a Node executable in a later adapter UI. A bundle root and fixture root must be explicit grants. The helper binds only `127.0.0.1` on an ephemeral port. It serves `diagnostic.html`, allowlisted bundle assets and allowlisted fixture files. It rejects remote navigation, popups, traversal, symlink escape and methods other than `GET` and `HEAD`.

## Future backend page bridge

An adapter page defines `window.takeformPreviewCommand(command)`, then posts one `takeformPreview` message after the actual preview state it is reporting. The message is:

```json
{"sessionID":"uuid","snapshotID":"string","displayedFrame":0,"playback":"paused","status":"painted"}
```

Commands are `load`, `seek`, `play` and `pause`. A page must preserve the supplied session and snapshot identity and report its actual displayed frame. The host rejects stale or malformed acknowledgements. The bridge deliberately does not calculate canonical timing. Backend adapters own their page timing and must document whether an acknowledgement means web paint, decoded source frame, or a render-backed frame.

## Checks

```sh
swift test
npm run test:helper
./script/build_app.sh
```

No check above launches the app or measures either renderer. Notarization, Developer ID signing, sandbox entitlement transfer and clean-Mac installation are unverified.
