# Renderer comparison harness

`common/` freezes one fixture snapshot and one versioned comparison treatment before either renderer runs. It uses Node built-ins and does not install, invoke, or benchmark a renderer.

The tool receives the fixture root as a command argument. It does not store that machine path in a snapshot, receipt, or source file. It validates every non-corrupt source against its declared SHA-256 and byte count. The declared unused corrupt M source remains visible. A corrupt source becomes an error when a canonical occurrence selects it.

Run the checks with Node 22 or later:

```sh
TAKEFORM_FIXTURE_ROOT=FIXTURE_ROOT node --test comparisons/common/index.test.mjs
node comparisons/common/cli.mjs validate --fixture-root FIXTURE_ROOT --accepted-commit 8a3daf1978093a3d67649b8f3779a9aa15fab876
node comparisons/common/cli.mjs inspect --fixture-root FIXTURE_ROOT --accepted-commit 8a3daf1978093a3d67649b8f3779a9aa15fab876 --fixture L --frame 2877
node comparisons/common/cli.mjs reserve --fixture-root FIXTURE_ROOT --accepted-commit 8a3daf1978093a3d67649b8f3779a9aa15fab876 --fixture L --route disk --expected-output-bytes 0
```

Validation elapsed time is tool overhead. It is not a render or performance result. The fake attempt lifecycle exists to test receipts only. It cannot produce renderer, visual, audio, or performance evidence.

The fixed treatment keeps twelve explicit M panel rectangles and rotations, T's caption and audio rules, and L's 24-frame transitions in source. `frameState()` uses rational time for every membership decision. It returns an error outside each half-open accepted frame range and never repeats the last frame.

## Adapter API

Both renderer adapters import [`common/frame-state.mjs`](common/frame-state.mjs). That file has no Node imports, file-system calls, hashes, or process state. It exports `comparisonTreatment`, `hydrateFrameState()`, and `frameState()`.

The Node-only loader returns an in-memory snapshot with `snapshotId`, `_manifests`, and `_treatment`. An adapter serializes those accepted values into its browser bundle, hydrates them once, and calls the shared function for every frame:

```js
import { frameState, hydrateFrameState } from '../common/frame-state.mjs';

const accepted = hydrateFrameState({ snapshotId, manifests, treatment });
const state = frameState(accepted, 'L', frame);
```

`manifests` is the loader's fixture map. The adapter must not reconstruct timing, source sampling, captions, or transition math. The returned state contains picture layers, exact source ranges and sample time, caption and author-chapter state, and audio envelope state. It declares a treatment and leaves backend mixing and normalization results null until a renderer records them.
