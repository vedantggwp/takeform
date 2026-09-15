# Native preview host

This is a native comparison host for issue #26. It is a SwiftUI app with a `WKWebView`, typed frame commands and an app-owned Node loopback helper. It does not contain a renderer or choose a renderer.

The controlled session records a backend, snapshot identity, rational frame rate, frame bounds, requested frame, displayed frame and acknowledged playback state. Every command has a monotonic request ID. Only the response for the current request can update displayed frame or playback. Superseded responses set the stale notice and preserve displayed state. The host records matched monotonic request and acknowledgement instants and shows the latest latency. The diagnostic page acknowledges after `requestAnimationFrame`. Its accessible delay control holds only the next acknowledgement for 150 ms to exercise stale-response handling. That demonstrates a web-paint callback only. It is not a decoded-frame or renderer output acknowledgement.

## Rendered preview

The **Rendered preview** panel remains unavailable until an authority-backed renderer supplies a verified artifact for the current plan revision. It accepts a typed descriptor containing the plan and snapshot identities, immutable renderer/settings/input digests, output hash and bytes, rational rate, frame count, expected audio/video stream counts, and validation-receipt reference. Its private cache copies into an owned staging directory, rejects symlinks and paths outside that root, verifies hash and byte count, and uses no-clobber publication.

Native playback uses `AVPlayerItemVideoOutput`. A `decoded` acknowledgement means the requested frame was accepted only after `hasNewPixelBuffer(forItemTime:)` and a copied pixel buffer; readiness or a host-time conversion alone does not count. Old revision/job/session results are refused, and cancellation removes only owned staging data. The panel does not expose a generic file picker or substitute an older cached result for the current plan.

The existing retained M and diagnostic T MP4s are developer-only test inputs. M contains no audio; T remains a diagnostic artifact. Neither establishes a creator workflow, source-composition parity, native listening evidence, or final A/V acceptance. No L artifact exists.

## Developer build

```sh
./script/build_app.sh
```

The script creates an ad-hoc signed app at `.build/bundle/Takeform Native Preview.app`. It copies the SwiftPM resource bundle, including the Node helper and diagnostic page, then checks the copied resource locations. It does not launch the app.

Node is an explicit developer dependency. On launch, set `TAKEFORM_NODE` through the developer launch environment or select a Node executable in the host UI. A bundle root and fixture root must be explicit grants. The helper binds only `127.0.0.1` on an ephemeral port. It streams `diagnostic.html`, allowlisted bundle assets and allowlisted fixture files. It supports one closed, open-ended or suffix byte range and returns 416 for invalid or multiple ranges. It rejects remote navigation, popups, traversal, symlink escape and methods other than `GET` and `HEAD`. Replacing or stopping a helper invalidates pending readiness, waits for termination and kills the owned process after two seconds if graceful shutdown does not finish.

## Future backend page bridge

An adapter page defines `window.takeformPreviewCommand(command)`, then posts one `takeformPreview` message after the actual preview state it is reporting. The message is:

```json
{"requestID":1,"sessionID":"uuid","snapshotID":"string","displayedFrame":0,"playback":"paused","status":"painted"}
```

Commands are `load`, `seek`, `play` and `pause`. A page must preserve the supplied request, session and snapshot identity and report its actual displayed frame. Response status is one of `painted`, `decoded` or `rendered`. The host rejects stale or malformed acknowledgements and accepts messages only from the selected top-level entry page. The bridge deliberately does not calculate canonical timing. Backend adapters own their page timing and must document whether an acknowledgement means web paint, decoded source frame, or a render-backed frame.

## Checks

```sh
swift test
npm run test:helper
./script/build_app.sh
```

No check above launches the app or measures either renderer. Notarization, Developer ID signing, sandbox entitlement transfer and clean-Mac installation are unverified.
