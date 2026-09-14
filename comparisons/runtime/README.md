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
| `remotion` | `4.0.524` | `sha512-jtoQbO7+UD7/4gcl0Onjq/Q27DP3qjI9hRimJJGuvU9p6OekY+Oyn1wNjYxG+hGH4i6InDFneN3sazFLuSF4Og==` | [Remotion core](https://github.com/remotion-dev/remotion/tree/main/packages/core) | [Remotion licence](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md). |
| `@remotion/renderer` | `4.0.524` | `sha512-0Rw/nsVu3OlPg11obmSm9ivLHAFYdZfpPxWFprHYWSeC82cLS4zEGdgy5tWUtuvQvaQ1MMohMhAzSEpqmsLgSQ==` | [Remotion renderer](https://github.com/remotion-dev/remotion/tree/main/packages/renderer) | [Remotion licence](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md). |
| `@remotion/player` | `4.0.524` | `sha512-MPaV64VKX4RFNFlEkoq7kKJKV6BfpSRdCAUKcjx6lVnF1VsSeb+wZKFGb3KvB8CzHYFkUM3RvhUi0JCxhnUmmA==` | [Remotion player](https://github.com/remotion-dev/remotion/tree/main/packages/player) | [Remotion licence](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md). |

`react` and `react-dom` are both pinned to `18.2.0`. The committed lockfile records their registry integrities.

The registry metadata identifies the two upstream repositories and package directories. It does not include a `gitHead` or an attestation tying the published tarballs to HyperFrames `d13a89b6707203a2efe2cfcd4e996e0ad0aa4573` or Remotion `9ca46edd6417b56cb10ae552f7a17027651d764c`. Package identity with those reviewed commits is unverified.

## Runtime facts

The first install used Node `22.22.1` and npm `10.9.4`. It took 7 seconds as setup cost. `node_modules` used 211012 KiB after installation. No browser was downloaded. The install began with 17489804 KiB free and ended with 17136696 KiB free. Both values exceed the 2 GiB free-space floor.

The doctor imports `@hyperframes/producer` and `@remotion/renderer`. It creates a HyperFrames job with `{num: 24000, den: 1001}` without rendering. It verifies Remotion's exported `ensureBrowser`, `openBrowser`, and `renderMedia` APIs without rendering.

HyperFrames documents `chromePath`, `PRODUCER_HEADLESS_SHELL_PATH`, and `HYPERFRAMES_BROWSER_PATH` as override routes. Remotion exposes `ensureBrowser({browserExecutable})` and `openBrowser('chrome', {browserExecutable})`. The pinned HyperFrames and Remotion launch implementations both add sandbox-disabling flags. This workspace does not call either launch API, so no BeginFrame or screenshot capability is claimed and no browser is shared. The custom executable bootstrap only confirms Remotion accepts the provided executable path.

## Browser launch proof

`browser/secure-browser-launcher.sh` is a caller-configured executable wrapper. Its target is provided through `TAKEFORM_BROWSER_EXECUTABLE`; the wrapper removes `--no-sandbox` and `--disable-setuid-sandbox`, rejects known web-security and site-isolation disabling flags, preserves other arguments, and replaces itself with the target process. It does not print the target path or unrestricted arguments.

Run the bounded probe with an explicit existing runtime and browser executable:

```sh
node comparisons/runtime/browser/probe.mjs --runtime RUNTIME_WORKSPACE --browser BROWSER_EXECUTABLE
```

The probe runs each SDK's documented executable override in a separate process, with a bounded timeout and owned temporary scratch space. It requests Remotion's isolated temporary profile and uses HyperFrames' exported capture-session route. Any successful path would capture a blank `data:` page and close it before cleanup. At the pinned versions, the wrapper safely rejects additional upstream web-security or site-isolation defaults before the real browser is executed. That result proves the override route and policy boundary only; it does not claim a browser launch, capture, OS-level sandbox attestation, or renderer capability.

No final licence determination is made here. Font availability, helper redistribution, browser distribution, and any production licensing decision remain open.

## Verification

```sh
npm test
npm run doctor -- --ffmpeg ffmpeg
```

The tests exercise missing private paths, unsupported Node, missing imports, invalid browser candidates, browser bootstrap failure, and a `TERM`-ignoring child. They do not render media or assert package-version strings.
