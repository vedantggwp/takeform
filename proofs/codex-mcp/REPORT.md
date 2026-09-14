# Codex MCP proposal proof

This proof models a generated three-scene project. The server advertises a read-only snapshot tool and a proposal tool. A proposal stays pending until a test creator accepts it. The source does not integrate with Takeform production authority, persistence, or UI.

## Result

The local MCP protocol and creator acceptance semantics passed. The real Codex model turn did not receive the MCP tools. The requested end-to-end proposal round trip therefore failed.

`codex exec --ignore-user-config --ephemeral` created an ephemeral `gpt-5.6-terra` turn. The turn reported 23,944 input tokens and 262 output tokens. The model replied that it could not access the Takeform tools. The proof server recorded no tool-list or tool-call event.

The no-model app-server check then reported the cause. Codex disabled project-local config in this untrusted project. The `.codex/config.toml` declaration therefore did not load. This is measured from the app-server stderr. A future retry needs a root-approved trusted-project or per-thread configuration route. It must precede another model turn.

## Local behavior

Run `npm test` in this directory. The test suite covers MCP framing and discovery, a pending proposal, explicit acceptance, duplicate acceptance, conflicting command IDs, malformed proposals, and stale proposals.

The proposal shape contains `expectedRevision`, `sceneID`, `replacementText`, and `commandID`. `ProposalStore.accept` performs compare-and-swap against the current revision. It returns the same result for a repeated accepted command ID.

`scripts/required-server-check.mjs` is a no-model app-server check. It starts an MCP server that exits immediately, marks it required, then starts an ephemeral thread. It returned a `thread/start` error that named the required server and its broken-pipe handshake. The command did not start a turn.

## Boundaries

The local tests establish only the toy store behavior and the standard-MCP server framing. The failed real turn establishes that this configuration route was not operational in the observed CLI invocation. It does not prove native Takeform authority, production persistence, creator UX, provider flexibility, or ChatGPT web connectivity.

## Evidence

The real-turn JSONL, tool-event log, final message, and stderr stayed in local scratch. The retained facts above contain only event types, generated values, and aggregate token usage. Raw reasoning was not retained.
