# Takeform v0.1 charter and executable feature map

14 September 2026. Proposed for v0.1. This document describes intent. There is no installable Takeform app today, and nothing below is a claim about running software. The [architecture proposal](architecture-proposal.md) explains ownership and open decisions. The [work map](roadmap.md) lists the work packages this document links to.

## 1. Charter

Takeform is for a solo creator who runs a channel from a Mac and wants agents to do bounded work inside it. Agents draft, propose and run typed commands, and the creator accepts, rejects or undoes each change as one unit. v0.1 promises one path from an idea, a script or footage to an exported film with a receipt, for a short episode and for a chaptered long episode. It promises that a channel formula saved once produces consistent episodes, and that every edit to a cut, a script or a format is reversible and inspectable. It promises that the app, a paired command line and agent tools issue the same commands and get the same results. It promises that a crash, a cancel or a forced quit loses no committed work and never becomes a silent duplicate of a paid request.

v0.1 refuses five things. Word timing is measured or absent, never inferred from the length of a phrase. A missing asset stays visibly missing instead of becoming a placeholder counted as done. A format change never rewrites an approved episode. A preview always states whether it shows the current revision and whether it is a proof render. A journey in this document is not done until linked evidence from a merged head says so.

## 2. Core requirement. Editable channel formulas

A format is a saved channel formula. It fixes the parts of an episode that stay the same across a channel and names the slots that vary. The fixed parts include beat structure, recurring visuals, typography, timing rules, caption treatment, sound rules and export profiles. Each variable slot carries bounds, such as a text length or a duration range. The architecture proposal calls the same object a recipe. This document uses format, the name used by [issue 6](https://github.com/vedantggwp/takeform/issues/6), which owns the work.

The requirement has three observable consequences. Each is a test to run, not a claim about today.

- A format saved once produces consistent episodes. Two episodes made from the same format version share the same treatment and differ only in their slot values.
- A format edit never silently changes an approved episode. Publishing a new format version leaves every existing episode on the version it was made with. Moving an episode to the new version is an explicit action that shows which overrides no longer validate before anything changes, and the move is refused while the episode is approved.
- Each episode pins a format version. The pinned version, the episode overrides and the resolved values are inspectable in the app without reading a file by hand.

Format versions are immutable, and identical content is one version. Journey J06 in the feature map is the test for this section.

## 3. Entry points

The three paragraphs below describe intended behaviour. Each entry point must reach an editable episode within three deliberate app actions, not counting file selection or text entry. None requires an account for local work.

### Idea

The creator names an audience and a takeaway and picks a format, or the built-in freeform format. Agents will propose a story treatment and the first script chunks, and nothing enters the episode until the creator accepts a proposal. The first observable state is an open episode with the takeaway at the top, a proposed treatment and proposed script chunks marked as needing review, and an empty shot list whose next action is to review the first chunk.

### Script

The creator pastes or opens a script. Takeform will split it into chunks, one per chapter for a long episode, and leave each chunk unapproved until the creator approves it. Takeform derives scenes and shot requirements from approved chunks, so none exist yet. The first observable state is an open episode with the script visible in chunks, every chunk marked unapproved, and a next action to approve the first chunk or to add footage.

### Footage

The creator drops files or a folder. No strategy questionnaire appears, and a silent montage needs no speech provider. Import will preserve the originals, pair a Live Photo still with its motion counterpart as one moment, mark an exact duplicate, and fail a corrupt file visibly without blocking the rest. The first observable state is an open episode on the freeform format with a media browser of imported moments, each item in a named state, and item counts that reconcile with what was dropped.

## 4. Paths

Short-form and long-form episodes use one episode model, one kind of format, one importer, one set of edit contracts and one exporter. A short-form episode is a single sequence, usually vertical, reviewed as one film. A long-form episode is chaptered and usually horizontal.

Three things differ between the paths.

- Chaptering. A long-form script is chunked by chapter. A chapter revision marks only its dependants for review and leaves the other chapters approved. Every chapter join is inspected for black gaps, extra end frames and audio continuity.
- Batch. A long-form episode or a series of episodes exports as a queue with bounded concurrency. The queue pauses, cancels and resumes without a duplicate completed output.
- Resume. Long renders and large imports are the jobs most likely to be interrupted. Progress is durable. After a crash or a forced quit, the episode reopens at its last committed revision and each interrupted job shows a recoverable state.

Four things are shared.

- Formats. One format can serve both paths and declares which slots a short episode and a long episode fill.
- Ingest. One importer with hashing, Live Photo pairing, duplicate detection, disposable proxies and quality warnings that separate measured faults from opinions.
- Edit contracts. Every edit is a typed command against a named project revision. A stale command conflicts instead of overwriting. Deletions, retimes and replacements are reversible with their source mapping intact. Agents propose by default and commit only inside a grant the creator issued.
- Export. Every export produces the film and a receipt that pins the content, the format version, the overrides, the rendering backend and the settings.

## 5. Executable feature map

Every row is planned today. No command, test target or evidence artifact below exists. Each command shape and test target is proposed, and the PR that creates one may rename it and must update its row. Fixture ids M, T and L are the montage, speech and thirty-minute fixtures owned by [issue 19](https://github.com/vedantggwp/takeform/issues/19). L is repeated synthetic material for renderer performance, cancellation and recovery evidence. It is never the sole proof that a chaptered creator film is accepted. C is a proposed chaptered-long acceptance fixture with distinct recorded or cleared content in each chapter and a complete story. S is a proposed story-first short fixture. Issue 19 or a child of it decides whether S is new material or a variant of T, and whether it owns C. Status uses three words, planned, implemented and verified, defined in section 7. A later PR names the journey id it advances.

| Journey id | Journey | Entry point | Path | Eventual test command | Evidence artifact | Work package | Status |
|---|---|---|---|---|---|---|---|
| J01 | Montage film. From dropped footage, make a short vertical montage with overlapping moments, deliberate crops, no repeated moment and no looped clip, then export it. | Footage | Short-form | `takeform verify montage --fixture M`, proposed | Exported film plus receipt, review recording | [#16](https://github.com/vedantggwp/takeform/issues/16), [#13](https://github.com/vedantggwp/takeform/issues/13), [#8](https://github.com/vedantggwp/takeform/issues/8) | planned |
| J02 | Talking-head film. From one recorded speech source, cut a talking-head edit that keeps its meaning, one pause and one self-correction, with corrected captions, then export it. | Footage | Short-form | `takeform verify talking-head --fixture T`, proposed | Exported film plus receipt, measurement JSON of the source to output timing map | [#16](https://github.com/vedantggwp/takeform/issues/16), [#11](https://github.com/vedantggwp/takeform/issues/11), [#14](https://github.com/vedantggwp/takeform/issues/14) | planned |
| J03 | Story-first short. From a takeaway, approve script chunks, break them into scenes and shots, fulfil the shots with quoted passages and B-roll, then export a short. | Idea | Short-form | `takeform verify story-short --fixture S`, proposed | Exported film plus receipt, screenshot set of the shot list | [#16](https://github.com/vedantggwp/takeform/issues/16), [#10](https://github.com/vedantggwp/takeform/issues/10), [#12](https://github.com/vedantggwp/takeform/issues/12) | planned |
| J04 | Chaptered long film. From a chapter script, produce a thirty-minute chaptered episode with captions and audio across every chapter join, revise one chapter, then export it. Acceptance uses C, with distinct chapter content and a complete story. | Script | Long-form | `takeform verify long --fixture C`, proposed. `takeform benchmark renderer --fixture L`, proposed, records independent stress evidence. | Exported C film plus receipt, source and output review recording with viewing and listening across every chapter join, and measurement JSON of C seek latency, peak memory and export time. The L benchmark is supporting performance and recovery evidence only. | [#16](https://github.com/vedantggwp/takeform/issues/16), [#15](https://github.com/vedantggwp/takeform/issues/15), [#13](https://github.com/vedantggwp/takeform/issues/13) | planned |
| J05 | Editable episode within three actions. From a fresh launch, start separately from an idea, a pasted script and dropped footage, then reach an editable episode within three deliberate actions each time. | Idea, Script, Footage | Both | XCUITest target `EntryPathTests`, proposed | Review recording with time to first editable result, screenshot set | [#7](https://github.com/vedantggwp/takeform/issues/7), [#10](https://github.com/vedantggwp/takeform/issues/10), [#8](https://github.com/vedantggwp/takeform/issues/8) | planned |
| J06 | Format creation and reuse. Save a format, make episodes A and B from version 1, publish version 2 and make episode C, then show A and B unchanged and C on version 2. | Idea | Both | XCUITest target `FormatReuseTests`, proposed | Exported films plus receipts for A, B and C, screenshot set of each effective value and its origin | [#6](https://github.com/vedantggwp/takeform/issues/6), [#7](https://github.com/vedantggwp/takeform/issues/7) | planned |
| J07 | Ingest with a Live Photo pair and a corrupt file. Drop a batch with a Live Photo pair, an exact duplicate and a corrupt file, then show one paired moment, one marked duplicate and one visible failure with counts that reconcile. | Footage | Both | `takeform verify ingest --fixture M`, proposed | Measurement JSON of the import report, screenshot set | [#8](https://github.com/vedantggwp/takeform/issues/8), [#19](https://github.com/vedantggwp/takeform/issues/19) | planned |
| J08 | Story-first breakdown with one replaced shot. Approve two chunks, fulfil their shots, replace one shot, then show only that shot's dependants needing review and every other approval intact. | Idea | Short-form | `takeform verify breakdown --fixture S`, proposed | Screenshot set of the dependency review, review recording | [#10](https://github.com/vedantggwp/takeform/issues/10), [#12](https://github.com/vedantggwp/takeform/issues/12) | planned |
| J09 | Reversible talking-head cut with a corrected word. Review proposed deletions against source playback, reject one, correct one word, undo, then show the passage and its timing restored and captions following the corrected transcript. | Footage | Short-form | `takeform verify rough-cut --fixture T`, proposed | Review recording, measurement JSON of the edit map before and after | [#11](https://github.com/vedantggwp/takeform/issues/11), [#14](https://github.com/vedantggwp/takeform/issues/14) | planned |
| J10 | Paired CLI and app issue the same command. Pair a command line session, submit the same edit command from the app and from the command line, then show identical receipts and one new project revision each. | Script | Both | XCUITest target `CommandParityTests` plus `takeform verify command-parity`, proposed | Measurement JSON of both receipts, screenshot set | [#9](https://github.com/vedantggwp/takeform/issues/9), [#18](https://github.com/vedantggwp/takeform/issues/18), [#7](https://github.com/vedantggwp/takeform/issues/7) | planned |
| J11 | Export presets for two aspect ratios. Export one episode with a portrait preset and a landscape preset, then show captions inside the safe area in both films and each receipt pinning its aspect ratio, resolution and frame rate. | Script | Both | `takeform verify presets --fixture T`, proposed | Two exported films plus receipts, screenshot set | [#14](https://github.com/vedantggwp/takeform/issues/14) | planned |
| J12 | Cancelled export leaves no partial receipt. Start a batch export, cancel one episode during its render, then show that episode marked cancelled with no receipt and no partial file at the destination. | Script | Long-form | `takeform verify export-cancel --fixture L`, proposed | Measurement JSON of the job ledger, screenshot set | [#15](https://github.com/vedantggwp/takeform/issues/15), [#13](https://github.com/vedantggwp/takeform/issues/13) | planned |
| J13 | Resume after a forced quit. Force quit during an import and during a render, reopen, then show committed work intact, interrupted jobs in recoverable states and no duplicate completed output. | Footage | Long-form | `takeform verify resume --fixture L`, proposed | Review recording, measurement JSON of the reconcile report | [#15](https://github.com/vedantggwp/takeform/issues/15), [#6](https://github.com/vedantggwp/takeform/issues/6) | planned |
| J14 | Fresh-machine setup. On a clean user account, clone the repository, run the doctor command, then build and launch the development build. Separately copy and launch an ad-hoc signed development bundle without the toolchain. Developer ID signing, notarization and distribution are a distinct planned path. They are unavailable until a valid Developer ID identity exists. | None, precedes entry | Both | `takeform doctor && swift build && swift test`, proposed, verifies the clone and development build. `scripts/package-dev-bundle && scripts/verify-dev-bundle --copied-to-clean-account`, proposed, verifies the copied ad-hoc bundle. `scripts/verify-developer-id-distribution`, proposed, is unavailable until a valid Developer ID identity exists. | Clone-path recording and doctor JSON. Ad-hoc bundle launch recording and `codesign -dv` receipt. Developer ID distribution evidence must record signing for the app and nested helpers, entitlements, notarization, stapling and clean-machine installation. | [#5](https://github.com/vedantggwp/takeform/issues/5), [#18](https://github.com/vedantggwp/takeform/issues/18), [#16](https://github.com/vedantggwp/takeform/issues/16) | planned |

## 6. Non-goals for v0.1

v0.1 does not include the following.

- Cloud collaboration or shared projects between machines.
- A marketplace for formats, assets or agents.
- Live streaming.
- Mobile capture or a companion phone app.
- Automatic publishing to platforms.
- Generative avatars or synthetic presenters.
- A second rendering backend after the comparison picks one.
- Windows or Linux builds.
- Per-entity merging of concurrent edits. v0.1 uses one project revision and reports a conflict.

The full production flow stays in scope. Story, script, shots, fulfilment, cut, composition, audio, captions, export, batch and revision each have a work package in the work map and a journey row above.

## 7. How this map is kept truthful

Status moves only with linked evidence at a merged head. A row becomes implemented when its test command or test target exists on main, ran at a named commit, and the PR links the run and its artifact. A row becomes verified when the root reviewed that artifact against the exact build and, for a film, the exported file itself, and recorded the verdict on the work package issue. Design proposals, type sketches and source inspection never count as runtime proof. Product interaction rows need a short video and screenshots, rendering rows need the rendered media and an audio check, and provider rows need a real bounded integration test with controlled failures, as the [review rules](roadmap.md#review-rules) in the work map require. A later change to the UI or the renderer returns every affected verified row to implemented until a focused rerun lands. A work package closes only when its rows are verified, and never because its first child merged.
