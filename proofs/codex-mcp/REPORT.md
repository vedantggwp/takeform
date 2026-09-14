# Codex MCP proposal proof

This proof models a generated three-scene project. The MCP server and creator control channel now share one ProposalStore. The control channel is an attempt-owned Unix socket that is not advertised to the model. This is a toy authority experiment, not Takeform production authorization.

## Result

The event-repaired no-model preflight passed on Codex CLI 0.154.0. The app-server catalog exposed takeform_snapshot and takeform_propose_edit. Nine currently configured unrelated servers exposed zero tools for this invocation. The ephemeral read-only thread returned no instruction sources, selected gpt-5.6-terra, and read revision 1 through the live MCP server. The earlier preflight remains evidence that eleven unrelated servers were disabled at that time; the current catalog has changed since that run.

The one permitted Terra turn completed in about 16 seconds. The repaired client observed and answered two `mcpServer/elicitation/request` events. Its conservative policy declined both, so no Takeform tool call reached the server and no proposal was created. The requested real model proposal round trip therefore remains failed. No second model turn ran.

After independent review of the narrowed matcher, one separately authorized Terra acceptance attempt completed in about 14 seconds. It again produced two MCP elicitation requests and no Takeform tool events. Both requests failed the reviewed matcher and were declined. The receipt captured 27,034 total tokens, including 27,027 input tokens, 25,344 cached input tokens, and 7 output tokens. No retry ran.

The acceptance receipt did not retain per-predicate rejection counters or allowlisted field-shape flags. The exact cause is now determined from the installed version and its pinned official release source: Codex 0.154.0 emits `codex_approval_kind` and `tool_params`, but does not emit the `tool_name` metadata field the old matcher required. That predicate was therefore false for both observed requests. The earlier raw request bodies were not retained, so the other old predicates cannot be reconstructed. The repaired matcher derives the one permitted operation from sequence and exact parameters instead of an absent field.

The raw event-run receipt is retained unchanged. Its `processCategory: configuration` value is a classifier false positive: the same receipt shows successful initialization, `turn/completed`, and process exit code 0. The classifier now attaches a process category only to early process exits. The run also received token-usage notifications but the old failure path did not copy the final value into the receipt; that path is repaired, but the missing value cannot be reconstructed without another model run.

The earlier blind run remains recorded in receipts/real-turn.json. It consumed 23,944 input tokens and exposed no Takeform tools. The earlier 90-second timeout remains recorded unchanged in receipts/real-turn-timeout.json. The new event trace does not prove that unanswered server requests caused that earlier timeout.

## Local behavior

ProposalStore rejects empty and whitespace-only replacement text. The server advertises snapshot and proposal tools. The private creator channel inspects and accepts proposals against the same in-memory store. Acceptance uses the existing compare-and-swap and idempotent command semantics.

The Node 22.22.1 suite passed thirteen tests. It proves revision 1 through MCP, a pending proposal without mutation, explicit creator acceptance through the private channel, and revision 2 through MCP. It also covers duplicate acceptance, conflicting command IDs, malformed proposals, whitespace replacement text, stale proposals, per-turn approval reset, allowlisted predicate diagnostics, and creator-socket shutdown on stdio EOF.

The app-server client now distinguishes server requests from responses, gives unsupported requests an explicit JSON-RPC error, declines supported but unauthorized requests, bounds notification and method buffers, and waits for process exit after SIGKILL. A fake app-server blocks on both an elicitation and an unsupported request before sending a structured failed completion. Another fixture ignores SIGTERM so the test can prove that cleanup waits for SIGKILL reaping.

The installed app-server schema lists eleven server-request methods. The driver gives only an exact, active-thread Takeform MCP approval a positive response. The metadata must name `mcp_tool_call`, omit the unsupported `tool_name` field, contain the next operation's explicit exact `tool_params` object, and use the supported empty-object form schema. Null, pre-turn, wrong-thread, repeated, reordered, or content-requiring requests are declined. Diagnostics retain only predicate booleans, value types, allowlisted field names, other-field counts, and the fixed Takeform operation name. The pinned [Codex 0.154.0 emitter source](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/core/src/mcp_tool_call.rs#L1835-L1965) defines this request shape. Its [correlation source](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/core/src/session/mcp.rs#L554-L624) sets the active turn sub-ID; app-server translates that to the active conversation and turn IDs while assigning its own pending request ID. Codex 0.154.0 does not expose the associated tool-call item ID on this request.

scripts/run-probe.mjs uses invocation-local `-c` overrides. Seven current configured servers were disabled with dotted `enabled=false` leaves. Two app-provided catalog entries do not accept that leaf shape, so the invocation masks them with disabled command stubs. The status catalog is cursor-paginated before the exact-tools gate. The model event cursor begins after the driver's revision 1 read. A successful model proof requires exactly two post-cursor events in order, with snapshot and proposal tool identities. Failure receipts contain only timestamps, method counts, pending request kinds, turn status, sanitized error codes, process exit, and bounded scratch inventory.

## Verification

- Node 22.22.1 initially ran node --test test/*.test.mjs. All twelve pre-diagnostic tests passed.
- Node 22.22.1 ran scripts/required-server-check.mjs without a model turn. The check passed.
- Node 22.22.1 ran scripts/run-probe.mjs with invocation-only disable flags. The paginated no-model catalog and revision 1 preflight passed.
- The same driver ran one low-effort Terra turn. It returned `turn/completed`, observed two MCP elicitations, declined both, and recorded no model tool event.
- The reviewed driver ran one separately authorized Terra acceptance attempt. It returned `turn/completed`, observed two declined MCP elicitations, recorded no model tool event, and captured exact token usage. No retry ran.
- Node 22.22.1 reran the expanded suite. All thirteen tests passed against a fake approval fixture derived from the pinned Codex 0.154.0 emitter contract.
- A fresh no-model preflight discovered the exact two Takeform tools and read revision 1 through `mcpServer/tool/call`. It observed zero elicitation requests, proving that this direct app-server method cannot reproduce the model approval boundary.

## Boundaries

The local tests prove the toy store mechanics and the client's request routing. The no-model receipt proves Codex app-server tool discovery and a live revision 1 read with explicit invocation configuration. The real-turn receipts prove that both completed turns reached the MCP approval boundary. They do not prove the proposal-to-acceptance round trip, the positive approval policy against a live turn, native Takeform authority, production persistence, creator UX, provider flexibility, or ChatGPT web connectivity.

One read-only diagnostic command unexpectedly printed an existing MCP environment credential while transport types were being investigated. The value was not copied into source, receipts, or reports. No further config dump or credential-bearing diagnostic ran.

Raw model reasoning was not retained. Public receipts contain generated values, aggregate settings, event facts, and no machine paths.
