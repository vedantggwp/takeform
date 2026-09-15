# Native creator walkthrough probe

This opt-in macOS UI probe tests the copied Takeform app through public XCTest
controls. It is separate from the F1 foundation probe and does not run on an
ordinary pull request. A maintainer applies the exact `native-creator-walkthrough-probe`
label, or manually dispatches an already-merged workflow with a reviewed SHA.
The job has read-only repository permission, an eight-minute job cap, and a
180-second owned XCTest process cap. It uploads only facts, the xcodebuild log,
the xcresult, and XCTest attachments for three days.

Every run uses a fresh runner-temporary root. The test target directly reuses
the cleared public media fixture builder for an 8×4 PNG, a VFR MOV, and a mono
AIFF, then uses the app's actual New Channel Save panel, Open Project panel,
and Import footage panel. It never injects a project document, calls
`ProjectAuthority` directly, changes host preferences, or uses personal media.

The first bounded suite records:

- native project creation, a first recipe, media import, authority-verified
  source inspection, episode composition save, quit, and native reopen;
- app-issued CLI pairing followed by a copied bundled CLI command, a stale
  revision conflict, native refresh, selected-grant revocation, and denied CLI
  reuse;
- a copied package's explicit native rebind decision and a deliberately corrupt
  manifest's typed recovery surface.

Each transition keeps a real screenshot and AX hierarchy attachment. The probe
makes no renderer, preview-export, or media-acceptance claim. Render completion
remains outside this suite until the reviewed renderer service adapter is in the
copied bundle.

The earlier hosted launch failures are retained as packaging evidence only: on
a case-insensitive APFS volume, the old `Takeform`/`takeform` layout let the
CLI replace the GUI binary. They are not native UI results. The copied bundle
now declares `TakeformApp` as its executable while retaining the lowercase CLI
as a distinct sibling, and the normal workflow runs all three creator cases.

The first run does not claim drag-and-drop or an in-flight cancellation outcome.
The next drag case will use XCTest's public
`click(forDuration:thenDragTo:)` from a Finder element representing a
runner-temporary fixture onto the identified Takeform drop target, with stage
screenshots and AX facts. The cancellation case needs a separately bounded,
parseable runner fixture and a visible in-flight import before it clicks the
actual Cancel import control and verifies no catalog commit. The picker route
covers image, video, and audio inspection.
