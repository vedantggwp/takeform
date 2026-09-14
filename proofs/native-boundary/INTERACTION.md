# Manual interaction check

This check lets the root inspect D3, D5 and D6 in the default developer topology. It uses the proof's own Keychain item and generated fixture only.

## Prepare the bundle

From `proofs/native-boundary`:

```sh
swift build -c release
./bundle.sh default
```

Copy `.build/bundle/Takeform Proof.app` to a new temporary directory. Launch that copied bundle through LaunchServices with `PROOF_AUTO=0` and a standard system-only `PATH`. The expected first screen shows `Takeform Proof`, a connected service, no fixture, no pairing requests and no sessions.

Use a fresh proof-only state directory and pass it through LaunchServices explicitly. This keeps the manual inspection independent from `run-proof.sh` receipts and avoids deleting any existing proof state:

```sh
UI_STATE="$(mktemp -d /tmp/takeform-proof-ui-state.XXXXXX)"
UI_COPY="$(mktemp -d /tmp/takeform-proof-ui-app.XXXXXX)"
ditto ".build/bundle/Takeform Proof.app" "$UI_COPY/Takeform Proof.app"
BIN="$UI_COPY/Takeform Proof.app/Contents/MacOS"
pkill -f "Takeform Proof.app/Contents/MacOS/ProofService" 2>/dev/null || true
open -n --env "PROOF_STATE_DIR=$UI_STATE" --env PROOF_AUTO=0 --env PATH=/usr/bin:/bin:/usr/sbin:/sbin "$UI_COPY/Takeform Proof.app"
```

Verify LaunchServices propagated the state directory before interacting:

```sh
for _ in {1..100}; do [ -S "$UI_STATE/proof.sock" ] && break; sleep 0.1; done
test -S "$UI_STATE/proof.sock"
PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" describe --no-token --expect rejected:unauthenticated
```

The CLI must be rejected as unauthenticated. The initial app screen must show no sessions, no pending requests and no fixture. Its creator status polling writes receipts, so a zero receipt count is not expected. Keep `PROOF_STATE_DIR="$UI_STATE"` on every manual CLI invocation below.

Compare this screen with `receipts/default/screens/01-launched.png`. The stored screenshot is supporting evidence. Inspect the live window through CUA for acceptance.

## D3. Pair and revoke

In a second terminal, set `BIN` to the copied app's `Contents/MacOS` directory, then run:

```sh
PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" forget
PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" pair --label "manual root check"
```

The second command waits. Within one status poll, the app shows a row under `Pairing requests (creator approves)` with the CLI PID and identifier `com.takeform.proof.cli`. Choose `Approve as proposer`.

Expected state:

- the terminal prints a token-free `paired` response with session ID, role and timing;
- the app moves the session to `Sessions` as `proposer active`;
- no token or token prefix appears in the app or terminal.

Run `PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" describe`. Before a fixture is selected, expect `rejected:noFixture`. Choose `Open fixture…` and select any harmless local file, then choose `Describe fixture`. The newest app receipt should say `describeFixture by creator`. Run `PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" describe` again. The terminal receipt should say `pairedCLI` and have the same receipt fields as the app receipt.

Choose `Revoke` beside the active session. Run `PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" describe` once more. Expect `rejected:revokedSession`. Compare the visible states with `receipts/default/screens/02-paired.png` and `receipts/default/screens/05-revoked.png`.

## D5. Start and cancel a helper

Choose `Start helper (8 s)`. The app should show an attempt line with an eight-character lease prefix, helper PID, process start time and state `running`. Compare it with `receipts/default/screens/03-attempt-running.png`.

Choose `Cancel attempt` before eight seconds pass. The same line should change to `cancelled` and show a cancel-to-exit value. Compare it with `receipts/default/screens/04-cancelled.png`.

For the CLI door, pair again, approve as proposer, then run `PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" start 20`. Copy the lease from the receipt and run `PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" cancel LEASE`. Expect a receipt that reports `SIGTERM to exit` with a measured duration. Then run `PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" write LEASE "late write"`. Expect `rejected:staleLease`.

## D6. Receipt replay

With the paired CLI, run twice:

```sh
PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" describe --id manual-same-command
PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" describe --id manual-same-command
```

Expected state: both results have the same `commandID`, `issuedAt`, principal, peer and result because the service returns the first receipt for a repeated command ID.

## Finish

Choose `Unregister` if the launch agent was registered during inspection. Quit the app. Run `PROOF_STATE_DIR="$UI_STATE" "$BIN/proofctl" forget` to delete only the proof CLI's Keychain item. The two `/tmp/takeform-proof-ui-*` directories are isolated proof artifacts and may be removed after inspection.
