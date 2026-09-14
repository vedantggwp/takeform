# Native app, authority and helper boundary proof

Status: measured developer proof with a distribution stop

Issue: Refs #18. This proof does not close the parent work packages.

## Decision

Go for the developer topology: a native SwiftUI client, one app-owned Swift service over a Unix domain socket, and leased helper processes. The default variant passed all 73 scripted checks. The app and CLI used the same command contract. The service derived principals from the peer audit token and code identity. Pairing, local credential storage failure, revocation, receipt replay, cancellation, service recovery and reused-PID protection behaved as designed.

No-go for distribution from this evidence. The sandbox variant launched the app but did not establish the app-to-service socket. `SMAppService` registration succeeded in the default variant, but launchd refused the ad-hoc nested service with `OS_REASON_CODESIGNING`. No Developer ID identity is installed, so Developer ID signing and notarization were not attempted.

The next packaging comparison should put the authority in a bundled XPC service and repeat D1 to D5 with a Developer ID or development provisioning profile. That comparison costs another small wire adapter, XPC lifecycle handling, app-group provisioning and the same negative-test matrix. Do not remove the sandbox or weaken authentication to make this topology pass.

## Measurements

The values below are measured on a Mac16,12 with Apple M4, 24 GiB memory, macOS 26.6.2 (25G83), Xcode 26.4 (17E192) and Swift 6.3. Each primary timing reports three raw runs and their median. Warm round trip reports five runs.

| Metric | Raw values in ms | Median in ms |
|---|---:|---:|
| App process start to first receipt | 384.628, 221.865, 211.983 | 221.865 |
| Service spawn to socket ready | 8.689, 10.922, 8.238 | 8.689 |
| Warm paired CLI round trip | 6.352, 2.163, 2.124, 1.909, 1.729 | 2.124 |
| Pair request to app approval | 18.000, 52.000, 69.000 | 52.000 |
| Approval to first authenticated receipt, including deliberate 250 ms delayed delivery | 286.000, 279.000, 283.000 | 283.000 |
| Cancel signal to helper exit | 0.8, 0.8, 0.8 | 0.8 |
| Service kill to socket restored | 120, 220, 214 | 214 |
| Relaunched service start to reconcile | 25.464, 35.327, 31.719 | 31.719 |
| Bundle size from `du -sk` | 3,604 KiB | n/a |

Raw values and checks are in `receipts/default/measurements-default.md`.

## D1. Service topology

Status: measured.

The app-owned process reached a Unix domain socket in the proof state directory, accepted commands and restarted after a forced service kill. Three spawn-to-socket runs measured 8.689, 10.922 and 8.238 ms. Three kill-to-restored-socket runs measured 120, 220 and 214 ms. `receipts/default/app-metrics.json`, `receipts/default/kill-*-wait.json` and `receipts/default/attempts.json` hold the evidence.

The alternative registered with `SMAppService` and reached status `enabled`. A launchd kickstart did not open the socket. `launchctl print` reported `last exit reason = OS_REASON_CODESIGNING` and `job state = spawn failed`. This is a measured ad-hoc-signing limit, not evidence that the topology fails with Developer ID signing. See `receipts/default/smappservice.txt`.

## D2. Peer authentication

Status: measured.

The service obtained `LOCAL_PEERTOKEN`, created a `SecCode` from the audit token and matched the app against `identifier "com.takeform.proof.app" and cdhash`. App receipts record `guestSource: audit`, `auditTokenObtained: true` and `matchesAppRequirement: true`. The CLI had identifier `com.takeform.proof.cli`, a different cdhash and `matchesAppRequirement: false`.

An unpaired CLI that claimed `actor: creator` remained unauthenticated. A paired CLI with the same forged claim remained `pairedCLI` and could not call creator-only commands. See `receipts/default/neg-2-forged-actor.json`, `receipts/default/neg-7-forged-paired.json` and `receipts/default/d6-receipts-both-doors.json`.

The Developer ID requirement check returned false because the binaries were ad-hoc signed. A production requirement would add the Developer ID anchor and Team ID to the identifier check.

## D3. Pairing

Status: measured.

An unauthenticated CLI could request pairing and could not submit or approve. The app approved three requests as `proposer`. Median request-to-approval time was 52.000 ms. Median approval-to-first-receipt time was 283.000 ms because the regression deliberately delayed grant delivery by 250 ms. During that delay, an immediate second approval with a different command ID was rejected as `pairingAlreadyDecided`; it could not mint or overwrite a session. Revoking sessions in the app made the next CLI call fail with `revokedSession`.

The raw `PairingGrant` exists only in process memory long enough for `proofctl` to put the token into its `com.takeform.proof.cli` login Keychain item. Observable CLI output uses a separate token-free response type. The service persists only the token SHA-256 digest. `proofctl audit-token-absence` reads its own Keychain item, searches receipt bytes for the issued value without printing it, and reports `issuedTokenPresent: false`. The runner repeats that audit after collecting the final receipt set. See `receipts/default/pair-*.json`, `receipts/default/keychain-item.txt`, `receipts/default/token-absence-final.json` and `receipts/default/neg-8-revoked.json`.

The focused local-storage negative forced Keychain status 100001 after server approval. The CLI kept the token-free `paired` response, recorded `serverExpectationMet: true`, `localCredentialStored: false` and a clear local credential error, set overall `pass: false`, skipped the transient-token follow-up, and exited 5. A normal recovery pair then stored its credential and completed the authenticated call. See `receipts/default/neg-keychain-store.json` and `receipts/default/keychain-recovery-pair.json`.

## D4. File access

Status: measured in the default variant; not run in the sandbox variant after its transport prerequisite failed.

The app generated a bookmark for a cleared two-second video fixture. The default service resolved it through the plain bookmark fallback, called `startAccessingSecurityScopedResource`, obtained the 32,662-byte size from file attributes and read the first 16 bytes. The helper opened the same file with AVFoundation and recorded two seconds with video and sound tracks. See `receipts/default/app-metrics.json`, `receipts/default/service-state.json` and `receipts/default/attempts.json`.

The sandbox bundle signed and passed local code verification. After the third bounded attempt, the app and service processes were running and the app-group state directory existed, but the Unix socket was absent. No first receipt appeared in any of the three 25-second observation windows. File access was therefore not run under the sandbox. The failure is before bookmark transfer. The sandbox receipt records the exact observable boundary in `receipts/sandbox/sandbox-boundary.txt` and `receipts/sandbox/app-metrics.json`.

## D5. Helper lifecycle

Status: measured in the default variant.

The service launched a separately signed nested helper. Before recording it as running, the service read the helper's first event and required the exact lease, PID and process start-time stamp to match its own launch observation. Three CLI cancellations stopped the helper in 0.8, 0.8 and 0.8 ms. App cancellation also reached `cancelled`. Writes under each finished lease failed with `staleLease`.

After three forced service kills, the relaunched service first required the persisted helper handshake to match the persisted lease and stamp. It then matched each live orphan by PID and start time, classified it `interrupted-helper-alive-same-start-time`, and signalled it. The reused-PID negative injected a live unrelated process with a trusted historical handshake but deliberately different live start time. Reconcile classified `interrupted-pid-reused-start-time-mismatch`, recorded `signalled: false` and left the process alive. See `receipts/default/attempt-*-cancel.json`, `receipts/default/attempt-*-stale-write.json` and `receipts/default/attempts-verified-handshakes.json`.

## D6. Same command through two doors

Status: measured.

The app and paired CLI submitted `describeFixture` through the same `Request`, `Command`, `Response` and `Receipt` types. Receipts from both principals have the same shape. Repeating command ID `d6-same-command-id` returned the first receipt with the same issue time. See `receipts/default/d6-cli-first.json`, `receipts/default/d6-cli-replay.json` and `receipts/default/d6-receipts-both-doors.json`.

## D7. Bundle

Status: measured for local developer packaging; not run for Developer ID distribution or notarization.

`bundle.sh` assembled the app, service, CLI, helper and launch-agent plist. It signed nested code inside out with the ad-hoc identity and hardened runtime. `codesign --verify --deep --strict` returned exit 0 for both variants. `spctl -a -vv` rejected both bundles with exit 3, as expected for ad-hoc distribution. Each nested binary's identity and entitlements are in `receipts/default/codesign-default.txt` and `receipts/sandbox/codesign-sandbox.txt`.

The default bundle was copied to a new temporary path and launched with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. It produced the full proof without Swift or the build toolchain on `PATH`. This proves local execution of the copied ad-hoc bundle. It does not prove fresh-machine trust, Developer ID validation, notarization, stapling or Gatekeeper acceptance.

## Developer build

Status: measured.

`swift build -c debug` and `swift build -c release` passed. The only compiler warnings are deprecated AVFoundation synchronous inspection and the complementary `CGWindowListCreateImage` screenshot path. The screenshot path is not root UX acceptance. Build tails are in `receipts/default/build-debug.txt` and `receipts/default/build-release.txt`.

`./run-proof.sh` rebuilt, bundled, signed, copied and drove the default experiment. Its final run reported 73 passes and zero failures. An injected failure-mode run exited 1, proving aggregate failures propagate to the process status. `VARIANT=sandbox ./run-proof.sh` stopped at the measured transport limit and labelled all dependent cases not run.

## Distribution

Status: not run beyond local ad-hoc checks.

`security find-identity -v -p codesigning` reported zero valid identities. Developer ID signing and notarization were not attempted. A fresh Mac can inspect the nested signatures and bundle structure. It cannot establish publisher identity, notarization, stapling or Gatekeeper acceptance from this artifact. `spctl` refusal and the `SMAppService` code-signing exit are the observed distribution gaps.

## Acceptance

| Item | Result |
|---|---|
| 1. Debug and release builds | Met |
| 2. Reproducible build, bundle, launch and scripted receipts | Met for the default variant |
| 3. D1 to D7 with evidence and status | Met |
| 4. Required negative tests | Met in the viable default topology |
| 5. Developer and distribution evidence separated | Met |
| 6. Go or no-go with alternative | Met |
| 7. Manual interaction script and screenshots | Met; root visual acceptance remains independent |
| 8. Hygiene | Met by the final scripts; only generated fixture data and proof screenshots are tracked |
| 9. Ready PR | Met by the ready PR carrying this proof |

## Limits and deviations

- The default fixture bookmark resolved through the plain fallback because `withSecurityScope` reported that the file was not in the correct format. File reading still succeeded in the unsandboxed service. Sandbox bookmark transfer was not run.
- The sandbox service children started but did not open their shared socket. No conclusive system error named the reason. The proof records the failed stage and does not claim a cause.
- `SMAppService` was compared directly and failed with the named launchd code-signing reason. XPC was not built.
- Screenshots were produced through the proof's internal window capture. Root CUA inspection is still required for direct-user-flow acceptance.
- No normal file edit was rejected in this run. The inherited interruption is documented outside this branch and was not counted as current verification.
