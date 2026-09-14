# Architecture evaluation record

14 September 2026. This is a record of the completed architecture evaluation for [issue #3](https://github.com/vedantggwp/takeform/issues/3). It records a design decision and its limits. It does not describe an implemented product or runtime result.

## Question and rubric

The common brief asked for one Mac-first video-studio architecture that supports editable, repeatable short and long films from an intention, script, footage, or a mix. It required one project authority, explicit time and format models, shared UI, CLI, and agent commands, bounded agent authority, renderer-neutral planning, crash-safe jobs, and public hygiene.

The hidden rubric scored six criteria from 0 to 5:

1. Caller-first shared contracts.
2. Domain and time invariants.
3. Durability, jobs, and concurrent edits.
4. Interface depth and red-flag screening.
5. Honest evidence and a conditional renderer.
6. Structural commitment.

The record retains the original packages by SHA-256. Each package fingerprint hashes a lexically sorted list of SHA-256 file digests in that package. The correction record and score records are individual-file digests.

| Artifact | SHA-256 |
|---|---|
| Candidate A package | `b280a0d151bcf45cda72c0f4c158165f7fa8ab12b32d1d6a4d004bfe98cb6c69` |
| Candidate B package | `9bab1d7b4d05fc2846a65d61cc6ecb4f568767114af7515f4c94254a4b50c1dc` |
| Candidate C package | `0a21de81d3a2b82494accf6049ba1e0e6b23a988bb925eab57f343cfcd383557` |
| Candidate D dropout record | `0d82565618eab0fd507fe6abc09c9c1caa9c9492cf69ec25869e6ba436e64219` |
| Final parent-score record | `a083af88f2cb7a54998657439d4c1def84acbcd74310534de9c3caa3003639b9` |
| Cross-judge verdict | `085a701b9b0e57eb653824351a98ae02dd3bfe60d024f51d2c68f493b75bd837` |
| Full-read correction record | `573e9334713864279839cc6a286a0ca224693d4974ee075e25b48efc47f13147` |

## Historical arena

The historical arena requested `claude-fable-5-1-thinking-max` for candidate A, `gpt-5.6-sol-max` for candidate B, `cursor-grok-4.6-high-fast` for candidate C, and `claude-opus-5-thinking-xhigh` for candidate D. A, B, and C produced complete design packages. D dropped out before dispatch because the delegation tool rejected its requested model label. No substitute ran.

The designs were structurally different. A used a linked Swift library with an elected writer. B used a native SwiftUI app, CLI, and agent tools over one signed on-demand Swift authority. C used a single-occupier document kernel with XPC helpers and an external recipe library.

The final parent and judge totals were:

| Candidate | Parent total | Judge total |
|---|---:|---:|
| A | 25 | 26 |
| B | 28 | 29 |
| C | 15 | 14 |

The provisional parent selection preceded a complete read of all type sketches. A later full read corrected the parent totals from A 26, B 29, and C 19 to the totals above. Candidate B remained the base. The original process was therefore not fully compliant from the start, even though the correction confirmed the same selection.

The cross-judge also authored candidate B. Path labels reduced direct attribution, but they did not remove that bias. The parent agreement after the full read is corroboration from another model family, not independent consensus.

## Selected design

Candidate B is the selected base. It proposes one signed Swift authority as the only writer of the project database. The app, CLI, and agent tools use the same typed command boundary. Workers receive immutable inputs and return receipts. Project-head compare-and-swap rejects stale content changes. The renderer remains separate from the project model until a measured comparison selects one.

The synthesis retained these additions:

- From A, rational frame rates, required word-alignment receipts, generated MCP schemas with drift checks, relink reporting, a footage-first recipe, approval-protected repins, preview identity and staleness labels, and segment caching with measured join rules.
- From B, a non-serializable command type with one validating wire codec, conflict context, the `provedNotSubmitted` reconciliation result, isolation receipts, JSON export as a projection, and a provider-flexible runtime by role.
- From C, shared moment identity for Live Photos, author-labelled chapters, direct footage or script entry, read-only recovery, projection recovery before rewrite, and public-hygiene checks.
- From the review correction, transitive freshness, lease-and-handshake worker identity, explicit unknown paid outcomes, quiesced relocation, complete export pins, bounded grants, paired sessions, and an explicit TypeScript-owner comparison.

The synthesis rejected caller-supplied identity, public receipt commands, stored freshness flags, aliased time ranges, inferred timing, PID-only liveness, automatic preview or provider fallbacks, and the claim that a TypeScript authority cannot isolate workers. It also rejected A's linked-writer base and C's document-kernel base for this product. TypeScript remains a viable ownership alternative if the native-service evidence fails.

## Evidence that remains open

No application, renderer, native preview, provider adapter, distribution package, or production database is accepted by this record.

[PR #28](https://github.com/vedantggwp/takeform/pull/28) contains the signed native-boundary probe and has an independent source-and-receipt review. Root-owned direct native UI and CLI interaction acceptance remains pending. The probe does not establish signed distribution, notarization, XPC, or sandbox capability transfer.

All renderer dependencies remain pending: [issue #19](https://github.com/vedantggwp/takeform/issues/19) defines the fixtures, [issue #24](https://github.com/vedantggwp/takeform/issues/24) measures HyperFrames, [issue #25](https://github.com/vedantggwp/takeform/issues/25) measures Remotion, [issue #26](https://github.com/vedantggwp/takeform/issues/26) measures native preview, and [issue #27](https://github.com/vedantggwp/takeform/issues/27) makes the decision. The decision record must include failed runs, licence status, preview behaviour, memory, seeking, export, cancellation, recovery, and output inspection before selecting a renderer.

The remaining runtime proofs are peer authentication and replay resistance, the launch-agent or XPC choice under sandbox and notarization, bundled runtime survival, the Codex tool route, provider-runtime isolation, licence eligibility, sandboxed interactive preview, and stream-join continuity. The native-service result can reopen the TypeScript authority comparison. None of these results is implied by the design evaluation.

## Current execution roles

The arena above is historical and used several provider labels. Current execution roles use Codex: Astra for coordination and final judgment, Sol for partner review, and Terra for bounded implementation or investigation. No fresh architecture comparison has been run under those roles.

Public artifacts must continue to exclude private paths, credentials, personal media, and previous-product branding.
