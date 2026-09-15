# Renderer runtime

This workspace prepares the pinned comparison dependencies. It does not render a fixture, measure timing, choose a renderer, or supply production code.

## Use

Run the doctor with the project Node 22 executable on `PATH`.

```sh
npm run doctor -- --ffmpeg ffmpeg
```

Pass explicit paths when an adapter needs a non-default executable.

```sh
npm run doctor -- --runtime . --ffmpeg ffmpeg --browser BROWSER_EXECUTABLE --bootstrap-browser
```

The command emits JSON. It does not print executable or runtime paths. Errors contain a diagnostic code and a concise public message. `--timeout-ms` bounds subprocess checks between 100 and 30000 milliseconds. A timed-out child receives `TERM`, then `KILL` after a short grace period, and the doctor waits for it to close. An explicit browser candidate must pass its version check even when bootstrap is not requested. The browser bootstrap verifies the Remotion public `ensureBrowser()` custom-executable route. It does not launch a browser.

## Pinned packages

| Package | Version | npm integrity | Registry repository metadata | Licence source |
| --- | --- | --- | --- | --- |
| `@hyperframes/producer` | `0.8.39` | `sha512-11MQVmQbk3zL3pfY+1SufDpMAct1CHfufi4YY7KrRY4FCkW/lLsW7pqRhxNFPEJRLoID32857CRL4aW6QyHOsw==` | [HyperFrames producer](https://github.com/heygen-com/hyperframes/tree/main/packages/producer) | npm metadata has no licence field. [Repository licence](https://github.com/heygen-com/hyperframes/blob/main/LICENSE). |
| `@hyperframes/engine` | `0.8.39` | `sha512-rRfqNi0m3HQW4xZ3YlD/PbeLi4o8kCFoXo5CM8rcUli7ooWRzs8gj3OmGQtaqayojbNC0haDWQ4CC+6OkmrtsQ==` | [HyperFrames engine](https://github.com/heygen-com/hyperframes/tree/main/packages/engine) | [Apache-2.0 package licence](https://github.com/heygen-com/hyperframes/blob/main/packages/engine/LICENSE). |
| `@hyperframes/player` | `0.8.39` | `sha512-sI0DwgEvf+hr78QRIUv9TKF7AoLGUQPJSqkbKkYiCjv5LfvkFrqhPThOt0re49WDwOnPsW67ZJZO+QafT4Md+w==` | [HyperFrames player](https://github.com/heygen-com/hyperframes/tree/main/packages/player) | npm metadata has no licence field. [Repository licence](https://github.com/heygen-com/hyperframes/blob/main/LICENSE). |
| `gsap` | `3.12.5` | `sha512-srBfnk4n+Oe/ZnMIOXt3gT605BX9x5+rh/prT2F1SsNJsU1XuMiP0E2aptW481OnonOGACZWBqseH5Z7csHxhQ==` | [GSAP 3.12.5 npm metadata](https://registry.npmjs.org/gsap/3.12.5) | [Standard no-charge licence](https://gsap.com/standard-license/), not MIT. |
| `remotion` | `4.0.524` | `sha512-jtoQbO7+UD7/4gcl0Onjq/Q27DP3qjI9hRimJJGuvU9p6OekY+Oyn1wNjYxG+hGH4i6InDFneN3sazFLuSF4Og==` | [Remotion core](https://github.com/remotion-dev/remotion/tree/main/packages/core) | [Remotion licence](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md). |
| `@remotion/renderer` | `4.0.524` | `sha512-0Rw/nsVu3OlPg11obmSm9ivLHAFYdZfpPxWFprHYWSeC82cLS4zEGdgy5tWUtuvQvaQ1MMohMhAzSEpqmsLgSQ==` | [Remotion renderer](https://github.com/remotion-dev/remotion/tree/main/packages/renderer) | [Remotion licence](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md). |
| `@remotion/bundler` | `4.0.524` | `sha512-xEx5ql0R00tadUUWduma/haiRNJzu30UmG8LMUpUW7bdCcO8KeRqq41I/BRn4PqStUGbpi7/zkTA6kZ8yzUIHA==` | [Remotion bundler](https://github.com/remotion-dev/remotion/tree/main/packages/bundler) | [Remotion licence](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md). |
| `@remotion/player` | `4.0.524` | `sha512-MPaV64VKX4RFNFlEkoq7kKJKV6BfpSRdCAUKcjx6lVnF1VsSeb+wZKFGb3KvB8CzHYFkUM3RvhUi0JCxhnUmmA==` | [Remotion player](https://github.com/remotion-dev/remotion/tree/main/packages/player) | [Remotion licence](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md). |

`react` and `react-dom` are both pinned to `18.2.0`. The committed lockfile records their registry integrities.

## HyperFrames player dependency proposal

`gsap@3.12.5` is pinned for the documented HyperFrames core `0.8.39` browser-composition contract: a composition registers a paused `gsap.timeline()` in `window.__timelines`. A future, explicitly granted player bundle will copy its local `dist/gsap.min.js` beside the exact nested `@hyperframes/player/node_modules/@hyperframes/core@0.8.39` runtime. It will not load GSAP or the core runtime from a CDN, and it will not use the generic engine `window.__hf` contract as a player substitute.

This change updates only this workspace's manifest and lockfile. It neither installs `gsap` into the shared runtime nor creates a player bundle. A dependency review must accept the licence and pinned tarball before an install or bundle build.

The registry metadata identifies the two upstream repositories and package directories. It does not include a `gitHead` or an attestation tying the published tarballs to HyperFrames `d13a89b6707203a2efe2cfcd4e996e0ad0aa4573` or Remotion `9ca46edd6417b56cb10ae552f7a17027651d764c`. Package identity with those reviewed commits is unverified.

## Runtime facts

The first install used Node `22.22.1` and npm `10.9.4`. It took 7 seconds as setup cost. `node_modules` used 211012 KiB after installation. No browser was downloaded. The install began with 17489804 KiB free and ended with 17136696 KiB free. Both values exceed the 2 GiB free-space floor.

The doctor imports `@hyperframes/producer`, `@remotion/renderer`, and `@remotion/bundler`. It creates a HyperFrames job with `{num: 24000, den: 1001}` without rendering. It verifies Remotion's exported `ensureBrowser`, `openBrowser`, `renderMedia`, and `bundle` APIs without rendering.

HyperFrames documents `chromePath`, `PRODUCER_HEADLESS_SHELL_PATH`, and `HYPERFRAMES_BROWSER_PATH` as override routes. Remotion exposes `ensureBrowser({browserExecutable})` and `openBrowser('chrome', {browserExecutable})`. The pinned launch implementations add sandbox-disabling and web-security weakening flags. The browser proof filters those known defaults at the executable boundary before the target starts. It does not share a browser.

## Browser launch proof

`browser/secure-browser-launcher.sh` is a caller-configured executable wrapper. Its target is provided through `TAKEFORM_BROWSER_EXECUTABLE`. It removes the pinned sandbox, mixed-content, site-isolation, and local/private-network weakening defaults, preserves unrelated arguments, and rejects explicit web-security or certificate-bypass requests. It replaces itself with the target process and does not print the target path or unrestricted arguments.

Run the bounded probe with an explicit existing runtime and browser executable:

```sh
node comparisons/runtime/browser/probe.mjs --runtime RUNTIME_WORKSPACE --browser BROWSER_EXECUTABLE
```

The probe runs each SDK's documented executable override in a separate process group, with a bounded timeout and owned temporary scratch space. It retains one blank capture per SDK under the ignored `browser/artifacts/` directory for review. Remotion uses documented new-headless mode with an isolated temporary profile. HyperFrames uses its exported capture-session route and a minimal local page that implements its documented `window.__hf` seek contract. On macOS, the measured HyperFrames mode is `screenshot`; this proof does not claim BeginFrame support. The runner drains capped child streams and terminates an owned process group on timeout. It proves the launch and capture routes plus absence of the filtered flags, not an OS-level sandbox attestation or renderer capability.

No final licence determination is made here. Font availability, helper redistribution, browser distribution, and any production licensing decision remain open.

## Verification

```sh
npm test
npm run doctor -- --ffmpeg ffmpeg
```

The tests exercise missing private paths, unsupported Node, missing imports, invalid browser candidates, browser bootstrap failure, a `TERM`-ignoring child, and the exact `@remotion/bundler` version. They do not render media.
