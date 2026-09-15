# Native UI capability probe

This opt-in GitHub Actions job tests whether the standard public `macos-26`
runner can start Apple's macOS UI-test runner, launch a copied F1 bundle,
read its accessibility tree and retain a screenshot of the actual window. It
does not accept F1, F3, distribution, rendering, media, or local-Mac behavior.

The job has only a `workflow_dispatch` trigger. Root enables it only after the
exact source head has passed independent source review. Dispatch it with the
full reviewed commit SHA; checkout verifies that SHA before it builds anything.

```sh
TAKEFORM_UI_PROBE_APP="/tmp/Takeform.app" \
TAKEFORM_UI_PROBE_OUTPUT="/tmp/takeform-ui-capability-artifacts" \
TAKEFORM_UI_PROBE_SOURCE_SHA="$(git rev-parse HEAD)" \
./scripts/run-native-ui-capability-probe
```

The public workflow supplies those paths below `$RUNNER_TEMP`, builds with the
existing pinned Xcode 26.4.1 path, packages the F1 app, and creates a fresh
copied bundle. The test launches that exact bundle through `XCUIApplication(url:)`.
It requires the native main window, the `takeform-title` accessibility
identifier, and the visible `Native development foundation` text. It stores an
`app.screenshot()` attachment with `keepAlways`; it does not call an in-app or
`CGWindowList` screenshot route.

The runner has 90 seconds for `xcodebuild` and the job has an eight-minute
ceiling. On success or failure the workflow uploads only the source SHA record,
the narrow xcodebuild log, facts, result bundle and exported test attachments
for three days. All app state is synthetic and runner-owned. No personal
files, media, credentials, Keychain items, broad environment dumps, or F3
authority paths are used.

For a local structural build that deliberately does not launch a UI test:

```sh
TAKEFORM_UI_PROBE_OUTPUT="/tmp/takeform-ui-capability-build" \
./scripts/run-native-ui-capability-probe --build-for-testing
```

If the hosted run cannot initialize the UI runner, expose AX elements, or
export the screenshot, that is a failed capability probe. Preserve its bounded
artifact and report the limitation; do not retry blindly or represent a
non-UI capture as user-flow evidence.
