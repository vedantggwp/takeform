# Renderer comparison harness

`common/` freezes one fixture snapshot and one versioned comparison treatment before either renderer runs. It uses Node built-ins and does not install, invoke, or benchmark a renderer.

The tool receives the fixture root as a command argument. It does not store that machine path in a snapshot, receipt, or source file. It validates the accepted schema and semantics for all three fixtures, resolves every declared source path without following symlinks, and hashes every source, including the declared unused corrupt M source. A corrupt source becomes an error when a canonical occurrence selects it. T's two measured word-timing receipts are also hashed into the snapshot identity.

Run the checks with Node 22 or later:

```sh
TAKEFORM_FIXTURE_ROOT=FIXTURE_ROOT node --test comparisons/common/index.test.mjs
node comparisons/common/cli.mjs validate --fixture-root FIXTURE_ROOT --accepted-commit 8a3daf1978093a3d67649b8f3779a9aa15fab876
node comparisons/common/cli.mjs inspect --fixture-root FIXTURE_ROOT --accepted-commit 8a3daf1978093a3d67649b8f3779a9aa15fab876 --fixture L --frame 2877
node comparisons/common/cli.mjs reserve --fixture-root FIXTURE_ROOT --accepted-commit 8a3daf1978093a3d67649b8f3779a9aa15fab876 --fixture L --route disk --expected-output-bytes 1000000000 --free-bytes 1000000000000
node comparisons/common/cli.mjs reserve --fixture-root FIXTURE_ROOT --accepted-commit 8a3daf1978093a3d67649b8f3779a9aa15fab876 --fixture T --route streaming --expected-output-bytes 1000000000 --decode-cache-bytes 2000000000 --pipeline-buffer-bytes 1000000000 --runtime-floor-bytes 4000000000 --free-bytes 1000000000000
```

Validation elapsed time is tool overhead. It is not a render or performance result. The fake attempt lifecycle exists to test receipts only. It cannot produce renderer, visual, audio, or performance evidence.

The fixed treatment keeps twelve explicit M panel rectangles and rotations, T's caption and audio rules, and L's 24-frame transitions in source. T's music envelope uses the measured word and acoustic-tail regions, applies 120 ms attack and 350 ms release with linear interpolation in dB, and exposes the canonical music occurrence, source range, and progressing sample time. L exposes bounded, progressing outgoing and incoming source sample times for every transition frame; the incoming range starts half a transition before its canonical chapter source start. `frameState()` uses reduced rational time for every membership decision. It rejects unsafe numeric inputs, returns an error outside each half-open accepted frame range, and never repeats the last frame.

## Adapter API

Both renderer adapters import [`common/frame-state.mjs`](common/frame-state.mjs). That file has no Node imports, file-system calls, hashes, or process state. It exports `comparisonTreatment`, `hydrateFrameState()`, and `frameState()`.

The Node-only loader returns an in-memory snapshot with `snapshotId`, `_manifests`, and `_treatment`. An adapter serializes those accepted values into its browser bundle, hydrates them once, and calls the shared function for every frame:

```js
import { frameState, hydrateFrameState } from '../common/frame-state.mjs';

const accepted = hydrateFrameState({ snapshotId, manifests, treatment });
const state = frameState(accepted, 'L', frame);
```

`manifests` is the loader's fixture map. The adapter must not reconstruct timing, source sampling, captions, or transition math. The returned state contains picture layers, exact source ranges and sample times, caption and author-chapter state, and audio envelope state. It declares normalization targets and leaves actual backend mixing and normalization results null until a renderer records them.

Real adapters use the Node-side lifecycle functions exported by `common/index.mjs`: `createAttempt()`, `finishAttempt()`, and `cleanupAttemptScratch()`. A renderer attempt names an accepted renderer identity, receives the snapshot object returned by `freezeSnapshot()` in the same process, owns one absolute attempt root, keeps scratch and output paths separate inside that root, and can complete only after the output file is inventoried and hashed. The receipt binds that file to the frozen snapshot. Cleanup is available only after terminal inventory, verifies that the attempt root is still the inventoried directory, and removes only the declared scratch paths. Failed or interrupted attempts never receive a completed output receipt.

The `attempt` CLI is deliberately narrower: it accepts only `--backend fake`, rejects output paths, and can exercise terminal inventory and optional cleanup without creating renderer evidence. Its attempt root basename must equal the attempt ID, and every comma-separated `--path` must be an owned, non-overlapping scratch path within that root.
