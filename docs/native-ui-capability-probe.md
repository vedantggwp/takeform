# Native UI capability probe

This opt-in GitHub Actions job tests whether the standard public `macos-26`
runner can start Apple's macOS UI-test runner, launch a copied F1 bundle,
read its accessibility tree and retain a screenshot of the actual window. It
does not accept F1, F3, distribution, rendering, media, or local-Mac behavior.

The probe commit contains CI tooling, not F1 product work. Its F1 production
sources, `Package.swift`, design assets, and dev-bundle script are verified
unchanged from F1 `63fc27ecbceec5c536983f749f4ef91fd9802a8a`; the copied app is
therefore source-equivalent to that F1 revision. The probe input SHA identifies
the reviewed tooling head. A successful probe can inform the F1 native gate,
but it does not complete any remaining F1 native case.

The job is opt-in only: root can dispatch it manually after merge with the full
reviewed commit SHA, or a maintainer can apply the exact
`native-ui-capability-probe` label to the reviewed pull request. It never runs
on ordinary pushes or pull requests, and it never uses `pull_request_target`.
Manual dispatch checks out its `source_sha`; a label run checks out that pull
request's head SHA. The job verifies the selected SHA before it builds anything.

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

The launcher passes the copied-app path only to the XCTest runner as
`TEST_RUNNER_TAKEFORM_UI_PROBE_APP`. Xcode strips the prefix before the test
reads `TAKEFORM_UI_PROBE_APP`; it is not an app-launch environment variable.
This is the documented `xcodebuild` transport for test-runner variables in the
[Xcode 13 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-13-release-notes)
(74104870) and the installed `xcodebuild` manual.

The runner has 90 seconds for `xcodebuild` and the job has an eight-minute
ceiling. On timeout the launcher terminates and reaps only the xcodebuild
process group and its discovered descendants. On success or failure the
workflow uploads only the source SHA record, narrow xcodebuild log, facts,
result bundle and exported test attachments for three days; derived data stays
on the runner. All app state is synthetic and runner-owned. No personal files,
media, credentials, Keychain items, broad environment dumps, or F3 authority
paths are used.

For a local structural build that deliberately does not launch a UI test:

```sh
TAKEFORM_UI_PROBE_OUTPUT="/tmp/takeform-ui-capability-build" \
./scripts/run-native-ui-capability-probe --build-for-testing
```

If the hosted run cannot initialize the UI runner, expose AX elements, or
export the screenshot, that is a failed capability probe. Preserve its bounded
artifact and report the limitation; do not retry blindly or represent a
non-UI capture as user-flow evidence.
