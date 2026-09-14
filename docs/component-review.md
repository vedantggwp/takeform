# Component review

Reviewed 14 September 2026. This is a shortlist based on upstream documentation, repository metadata and selected source inspection. It is not a renderer benchmark. No candidate is adopted yet. Follow issues #2, #3 and #4 for source review, architecture and measured comparisons.

## Make repeatable formats a core capability

A channel format defines the parts that remain fixed and the slots that vary. These include story beats, timing ranges, typography, recurring visuals, caption treatments, sound rules and export profiles. Each episode pins a format version and records its overrides. A format update must not silently rewrite an approved episode.

HyperFrames documents typed composition variables and batch rendering. This is a useful rendering mechanism, but a channel format also needs script structure, shot requirements, context and revision rules.

## HeyGen components

| Component | Observed capability | Decision for investigation |
|---|---|---|
| [HyperFrames](https://github.com/heygen-com/hyperframes) | HTML composition, seekable animation, local render, player, evolving Studio and audio tooling. Apache 2.0 upstream licence | Primary renderer comparison candidate |
| [Composition variables](https://github.com/heygen-com/hyperframes/blob/main/docs/concepts/variables.mdx) | Typed values, nested composition overrides, strict validation and batch rows | Investigate as the rendering layer beneath channel formats |
| [Studio timeline](https://github.com/heygen-com/hyperframes/blob/main/docs/studio/timeline.mdx) | Move, trim, eligible splits, nested scenes, undo, virtualized keyboard navigation and treegrid semantics | Reference for editor operations and accessibility; verify embed behaviour on Mac |
| [HeyGen CLI](https://github.com/heygen-com/heygen-cli) | JSON output, schema discovery, structured errors, async job IDs and generation operations | Good external-provider adapter candidate. Hosted video generation remains a paid service |
| [HeyGen skills](https://github.com/heygen-com/skills) | Avatar identity, video creation and translation workflows | Optional presenter workflow and context reference; not required for owned-footage editing |
| [HeyGen Stack](https://github.com/heygen-com/heygen-stack) | README says development moved to skills | Do not adopt the archived entry point |
| [HyperFrames launches](https://github.com/heygen-com/hyperframes-launches) | Composition source, nested scenes and storyboards for actual launch videos | Study motion and scene structure. Its licence explicitly excludes bundled media, fonts and brand assets |
| [Gemini agent example](https://github.com/heygen-com/hyperframes-gemini-agent) | Select starter, write content, validate variables, submit render | Useful example of fixed formulas. Preview integration and validator limits prevent wholesale adoption |
| [Vercel template](https://github.com/heygen-com/hyperframes-vercel-template), [Cloudflare template](https://github.com/heygen-com/hyperframes-cloudflare-template), [Modal template](https://github.com/heygen-com/hyperframes-modal-template) | Deployment paths listed in the upstream organisation | Inventory only. Inspect after a real need for remote rendering is established |
| [TransVLM](https://github.com/heygen-com/TransVLM) | Released inference and evaluation code for transition intervals, not merely cut points | Research reference. Current instructions require Python 3.12 and CUDA; not a default Mac dependency |
| [LiveAvatar SDK](https://github.com/heygen-com/liveavatar-web-sdk) and [live demos](https://github.com/heygen-com/liveavatar-gpt-live-demos) | Interactive avatar ecosystem | Inventory only. Optional future recording or presenter workflow, not the core editor |
| [TAVR](https://github.com/heygen-com/TAVR) | New talking-avatar research repository | Inventory only; no adoption claim |

TransVLM's README explicitly separates its academic model from HeyGen's production system. Its benchmark data and data engine remain unreleased in the checked README. Do not equate a research release with a production-tested local feature.

## One verified issue in the Gemini example

Read the complete [customize.py](https://github.com/heygen-com/hyperframes-gemini-agent/blob/main/workspace/scripts/customize.py). Its `build_variables` validates supplied values but copies omitted defaults without validation. A local synthetic probe returned `{'count': 'wrong'}` for a declared numeric slot with a string default. Supplying the same string explicitly was rejected. A captured run of [probes/hyperframes-customize-probe.sh](probes/hyperframes-customize-probe.sh) is in [probes/hyperframes-customize-probe.out.txt](probes/hyperframes-customize-probe.out.txt).

This is a bounded finding in that example helper, not evidence of a defect in HyperFrames core. It means a reused validator must check the resolved values, including defaults. The helper also supports fewer variable types than the current HyperFrames documentation, which now lists font and image inputs.

The Gemini example's README says its exact Interactions API request/response shape is still being confirmed. The example is therefore not evidence that a complete managed-agent integration works for this product.

## Other approaches worth comparing

| Candidate | What to learn | Limitation or decision |
|---|---|---|
| [Remotion](https://github.com/remotion-dev/remotion) | React compositions, media tooling, reusable motion components and rendering tests | Primary comparison candidate. Review its conditional licence and separate browser-renderer limitations |
| [OpenCut](https://github.com/OpenCut-app/OpenCut) | Editor API, plugin and headless architecture direction | Main README announces a rewrite. Do not count its planned features as current delivery |
| [OpenCut Classic](https://github.com/opencut-app/opencut-classic) | Existing editor implementation named by upstream as the usable version | Follow-up source and interaction review required |
| [FableCut](https://github.com/ronak-create/FableCut) | Agent-controlled editing, shared project representation and human/agent coexistence | Promising direct comparator. README speed claims and concurrency need independent tests |
| [Diffusion Studio Core](https://github.com/diffusionstudio/core) | Canvas/WebCodecs playback and export, layers, keyframes and checkpoints | Alternative engine. MPL 2.0 metadata; last pushed date observed was November 2025. Compatibility and maintenance require scrutiny |
| [Auto-Editor](https://github.com/WyattBlue/auto-editor) | Configurable audio and motion selection with margins and editor export | Strong rough-cut baseline. Silence detection is not editorial understanding |
| [Argmax OSS Swift](https://github.com/argmaxinc/argmax-oss-swift) | On-device transcription, diarization and speech generation for Apple Silicon | Strong native candidate. Select individual products; distinguish OSS from Pro capabilities and model terms |
| [MLT](https://github.com/mltframework/mlt) | Mature media-editing engine and plugin boundaries | Native-engine alternative. Benchmark integration and distribution complexity before adoption |
| [OpenTimelineIO](https://opentimelineio.readthedocs.io/en/latest/) | Editable timeline interchange and media references | Interchange candidate, not the story model or renderer |
| [Final Cut Pro](https://www.apple.com/final-cut-pro/) | Connected edits, roles, transcript search, proxies and native project interactions | Interaction reference. Do not copy proprietary implementation or branding |

These are candidates, not a ranked list of popularity. Current releases, activity and publicity help discovery but do not prove suitability.

## Evidence needed for the decision

Test the same synthetic or cleared media in each serious renderer candidate. Include a montage with overlapping videos, a talking-head cut with corrected captions, and a chaptered long video. Measure native preview seeking, output timing, audio sync, render time and peak memory. Inspect the full outputs and exact cut boundaries.

Test versioned format defaults, invalid slot values, overly long text, missing assets, one-shot replacement and cancelled generation. Prove that a manual edit and an agent edit cannot silently overwrite each other. Compare dependency installation and packaged helper startup on a fresh machine.

Choose a rendering engine after those measurements. Avoid committing to multiple complete engines in v0.1 merely to retain options.
