# Codex MCP proposal proof

This proof models a generated three-scene project. The MCP server and creator control channel now share one ProposalStore. The control channel is an attempt-owned Unix socket that is not advertised to the model. This is a toy authority experiment, not Takeform production authorization.

## Result

The event-repaired no-model preflight passed on Codex CLI 0.154.0. The app-server catalog exposed takeform_snapshot and takeform_propose_edit. Nine currently configured unrelated servers exposed zero tools for this invocation. The ephemeral read-only thread returned no instruction sources, selected gpt-5.6-terra, and read revision 1 through the live MCP server. The earlier preflight remains evidence that eleven unrelated servers were disabled at that time; the current catalog has changed since that run.

The one permitted Terra turn completed in about 16 seconds. The repaired client observed and answered two `mcpServer/elicitation/request` events. Its conservative policy declined both, so no Takeform tool call reached the server and no proposal was created. The requested real model proposal round trip therefore remains failed. No second model turn ran.

The raw event-run receipt is retained unchanged. Its `processCategory: configuration` value is a classifier false positive: the same receipt shows successful initialization, `turn/completed`, and process exit code 0. The classifier now attaches a process category only to early process exits. The run also received token-usage notifications but the old failure path did not copy the final value into the receipt; that path is repaired, but the missing value cannot be reconstructed without another model run.

The earlier blind run remains recorded in receipts/real-turn.json. It consumed 23,944 input tokens and exposed no Takeform tools. The earlier 90-second timeout remains recorded unchanged in receipts/real-turn-timeout.json. The new event trace does not prove that unanswered server requests caused that earlier timeout.

## Local behavior

ProposalStore rejects empty and whitespace-only replacement text. The server advertises snapshot and proposal tools. The private creator channel inspects and accepts proposals against the same in-memory store. Acceptance uses the existing compare-and-swap and idempotent command semantics.

The Node 22.22.1 suite passed nine tests. It proves revision 1 through MCP, a pending proposal without mutation, explicit creator acceptance through the private channel, and revision 2 through MCP. It also covers duplicate acceptance, conflicting command IDs, malformed proposals, whitespace replacement text, and stale proposals.

The app-server client now distinguishes server requests from responses, gives unsupported requests an explicit JSON-RPC error, declines supported but unauthorized requests, bounds notification and method buffers, and waits for process exit after SIGKILL. A fake app-server blocks on both an elicitation and an unsupported request before sending a structured failed completion. Another fixture ignores SIGTERM so the test can prove that cleanup waits for SIGKILL reaping.

The installed app-server schema lists eleven server-request methods. The driver gives only an exact, same-turn Takeform MCP approval a positive response: the metadata must name `mcp_tool_call`, identify one of the two expected tools, contain the exact expected arguments, and request no form fields. Everything else is declined or rejected. The current [Codex app-server source](https://github.com/openai/codex/blob/main/codex-rs/core/src/session/mcp.rs) uses the same approval metadata and accepts approved MCP calls with empty content.

scripts/run-probe.mjs uses invocation-local `-c` overrides. Seven current configured servers were disabled with dotted `enabled=false` leaves. Two app-provided catalog entries do not accept that leaf shape, so the invocation masks them with disabled command stubs. The status catalog is cursor-paginated before the exact-tools gate. The model event cursor begins after the driver's revision 1 read. Failure receipts contain only timestamps, method counts, pending request kinds, turn status, sanitized error codes, process exit, and bounded scratch inventory.

## Verification

- Node 22.22.1 ran node --test test/*.test.mjs. All nine tests passed.
- Node 22.22.1 ran scripts/required-server-check.mjs without a model turn. The check passed.
- Node 22.22.1 ran scripts/run-probe.mjs with invocation-only disable flags. The paginated no-model catalog and revision 1 preflight passed.
- The same driver ran one low-effort Terra turn. It returned `turn/completed`, observed two MCP elicitations, declined both, and recorded no model tool event.

## Boundaries

The local tests prove the toy store mechanics and the client's request routing. The no-model receipt proves Codex app-server tool discovery and a live revision 1 read with explicit invocation configuration. The real receipt proves that this turn reached the MCP approval boundary. It does not prove the proposal-to-acceptance round trip, the new positive approval policy against a live turn, native Takeform authority, production persistence, creator UX, provider flexibility, or ChatGPT web connectivity.

One read-only diagnostic command unexpectedly printed an existing MCP environment credential while transport types were being investigated. The value was not copied into source, receipts, or reports. No further config dump or credential-bearing diagnostic ran.

Raw model reasoning was not retained. Public receipts contain generated values, aggregate settings, event facts, and no machine paths.
