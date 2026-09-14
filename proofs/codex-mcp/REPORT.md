# Codex MCP proposal proof

This proof models a generated three-scene project. The MCP server and creator control channel now share one ProposalStore. The control channel is an attempt-owned Unix socket that is not advertised to the model. This is a toy authority experiment, not Takeform production authorization.

## Result

The repaired no-model preflight passed on Codex CLI 0.154.0. The app-server catalog exposed takeform_snapshot and takeform_propose_edit. Eleven unrelated configured servers exposed zero tools for this invocation. The ephemeral read-only thread returned no instruction sources, selected gpt-5.6-terra, and read revision 1 through the live MCP server.

The one permitted Terra turn did not complete within the driver's 90-second bound. It made no proposal tool call, returned no token usage, and was terminated with the app-server process. No second model turn ran. The requested real model proposal round trip therefore remains failed.

The earlier blind run remains recorded in receipts/real-turn.json. It consumed 23,944 input tokens and exposed no Takeform tools. The repaired run did not repeat that failure mode because receipts/preflight.json proves discovery before the turn.

## Local behavior

ProposalStore rejects empty and whitespace-only replacement text. The server advertises snapshot and proposal tools. The private creator channel inspects and accepts proposals against the same in-memory store. Acceptance uses the existing compare-and-swap and idempotent command semantics.

The Node 22.22.1 suite passed five tests. It proves revision 1 through MCP, a pending proposal without mutation, explicit creator acceptance through the private channel, and revision 2 through MCP. It also covers duplicate acceptance, conflicting command IDs, malformed proposals, whitespace replacement text, and stale proposals.

scripts/required-server-check.mjs now resolves codex from PATH or --codex. Its requests reject on child exit or timeout. The live no-model check passed only after the returned error named required_failure and described an MCP startup failure.

scripts/run-probe.mjs uses the documented app-server -c override and generated app-server schemas. Callers supply repeatable --disable-server or --disable-http-server flags for unrelated local MCP entries. Each disabled entry retains a valid transport shape. The driver fails before a turn unless only the two Takeform tools are exposed. The official configuration reference documents mcp_servers.<id>.enabled, required, enabled_tools, and the timeout fields.

## Verification

- Node 22.22.1 ran node --test test/*.test.mjs. All five tests passed.
- Node 22.22.1 ran scripts/required-server-check.mjs without a model turn. The check passed.
- Node 22.22.1 ran scripts/run-probe.mjs with invocation-only disable flags. The no-model catalog and revision 1 preflight passed.
- The same command with --turn timed out before turn/completed. It made no model proposal call.

## Boundaries

The local test proves only toy store mechanics. The no-model receipt proves Codex app-server tool discovery and a live revision 1 read with explicit invocation configuration. Neither proves native Takeform authority, production persistence, creator UX, provider flexibility, or ChatGPT web connectivity.

One read-only diagnostic command unexpectedly printed an existing MCP environment credential while transport types were being investigated. The value was not copied into source, receipts, or reports. No further config dump or credential-bearing diagnostic ran.

Raw model reasoning was not retained. Public receipts contain generated values, aggregate settings, event facts, and no machine paths.
