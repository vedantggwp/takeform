import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { AppServer, mcpToolApprovalPolicy } from "../src/app-server-client.mjs";

const PROPOSAL = {
  expectedRevision: 1,
  sceneID: "scene-2",
  replacementText: "Show the decision that changes the result.",
  commandID: "proposal-live-20260914"
};

function approvalMessage(tool, toolParams, overrides = {}) {
  const params = {
    serverName: "takeform",
    threadId: "thread-1",
    turnId: "turn-1",
    mode: "form",
    requestedSchema: { type: "object", properties: {} },
    _meta: { codex_approval_kind: "mcp_tool_call", tool_name: tool, tool_params: toolParams },
    ...overrides
  };
  return { method: "mcpServer/elicitation/request", params };
}

function orderedPolicy(active = { threadId: "thread-1", turnId: "turn-1" }) {
  return mcpToolApprovalPolicy({
    serverName: "takeform",
    calls: [
      { tool: "takeform_snapshot", arguments: {} },
      { tool: "takeform_propose_edit", arguments: PROPOSAL }
    ],
    getActiveTurn: () => active
  });
}

test("server requests are declined and a structured completion remains observable", async () => {
  const fixture = fileURLToPath(new URL("fixtures/fake-app-server.mjs", import.meta.url));
  const app = new AppServer(process.execPath, [fixture]);
  try {
    await app.request("initialize", {});
    await app.waitFor((message) => message.method === "serverRequest/resolved");
    const started = await app.request("turn/start", {});
    const completed = await app.waitFor((message) => message.method === "turn/completed");
    assert.equal(started.turn.id, "fake-turn");
    assert.equal(completed.params.turn.status, "failed");
    assert.equal(completed.params.turn.error.code, "fake_failure");
    assert.deepEqual(app.diagnostics(), {
      pendingRequestKinds: [],
      receivedMethodCounts: {
        "item/tool/call": 1,
        "mcpServer/elicitation/request": 1,
        other: 1,
        "turn/completed": 1
      },
      requestOutcomes: { declined: 1, unsupported: 1 }
    });
  } finally {
    const exit = await app.close();
    assert.equal(exit.code, 0);
  }
});

test("close waits until a SIGTERM-resistant app-server is reaped", async () => {
  const fixture = fileURLToPath(new URL("fixtures/fake-app-server.mjs", import.meta.url));
  const app = new AppServer(process.execPath, [fixture, "--ignore-term"]);
  await app.request("initialize", {});
  const exit = await app.close();
  assert.equal(exit.signal, "SIGKILL");
});

test("only an exact Takeform tool approval is accepted", async () => {
  const fixture = fileURLToPath(new URL("fixtures/fake-app-server.mjs", import.meta.url));
  const app = new AppServer(process.execPath, [fixture, "--takeform-approval"], {
    serverRequestPolicy: mcpToolApprovalPolicy({
      serverName: "takeform",
      calls: [{ tool: "takeform_snapshot", arguments: {} }],
      getActiveTurn: () => ({ threadId: "fake-thread", turnId: "fake-turn" })
    })
  });
  try {
    await app.request("initialize", {});
    await app.waitFor((message) => message.method === "serverRequest/resolved");
    await app.request("turn/start", {});
    const completed = await app.waitFor((message) => message.method === "turn/completed");
    assert.equal(completed.params.turn.status, "failed");
    assert.equal(app.diagnostics().requestOutcomes.approved, 1);
  } finally {
    await app.close();
  }
});

test("Takeform approval accepts one ordered snapshot and the fixed proposal", () => {
  const policy = orderedPolicy();
  assert.deepEqual(policy(approvalMessage("takeform_snapshot", {})), { result: { action: "accept", content: {} } });
  assert.deepEqual(policy(approvalMessage("takeform_propose_edit", PROPOSAL)), { result: { action: "accept", content: {} } });
});

test("Takeform approval rejects wrong scope, schema, arguments, and repeats", () => {
  assert.equal(orderedPolicy()(approvalMessage("takeform_snapshot", {}, { serverName: "other" })), null);
  assert.equal(orderedPolicy()(approvalMessage("takeform_snapshot", {}, { threadId: "thread-2" })), null);
  assert.equal(orderedPolicy()(approvalMessage("takeform_snapshot", {}, { turnId: "turn-2" })), null);
  assert.equal(orderedPolicy({ threadId: "", turnId: "" })(approvalMessage("takeform_snapshot", {})), null);
  assert.equal(orderedPolicy(null)(approvalMessage("takeform_snapshot", {})), null);
  assert.equal(orderedPolicy()(approvalMessage("takeform_snapshot", {}, {
    requestedSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] }
  })), null);
  assert.equal(orderedPolicy()(approvalMessage("takeform_snapshot", { extra: true })), null);

  const repeated = orderedPolicy();
  assert.deepEqual(repeated(approvalMessage("takeform_snapshot", {})), { result: { action: "accept", content: {} } });
  assert.equal(repeated(approvalMessage("takeform_snapshot", {})), null);
  assert.deepEqual(repeated(approvalMessage("takeform_propose_edit", PROPOSAL)), { result: { action: "accept", content: {} } });
  assert.equal(repeated(approvalMessage("takeform_propose_edit", PROPOSAL)), null);
});

test("Takeform approval sequence resets only for a new active turn", () => {
  let active = { threadId: "thread-1", turnId: "turn-1" };
  const policy = mcpToolApprovalPolicy({
    serverName: "takeform",
    calls: [
      { tool: "takeform_snapshot", arguments: {} },
      { tool: "takeform_propose_edit", arguments: PROPOSAL }
    ],
    getActiveTurn: () => active
  });
  assert.ok(policy(approvalMessage("takeform_snapshot", {})));
  assert.ok(policy(approvalMessage("takeform_propose_edit", PROPOSAL)));
  active = { threadId: "thread-1", turnId: "turn-2" };
  assert.ok(policy(approvalMessage("takeform_snapshot", {}, { turnId: "turn-2" })));
});
