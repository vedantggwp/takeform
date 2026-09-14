import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { AppServer, mcpToolApprovalPolicy } from "../src/app-server-client.mjs";

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
      calls: { takeform_snapshot: {} },
      getTurnId: () => "fake-turn"
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

test("Takeform approval rejects a different tool or arguments", () => {
  const policy = mcpToolApprovalPolicy({
    serverName: "takeform",
    calls: { takeform_snapshot: {} },
    getTurnId: () => "turn-1"
  });
  const base = {
    method: "mcpServer/elicitation/request",
    params: {
      serverName: "takeform",
      threadId: "thread-1",
      turnId: "turn-1",
      mode: "form",
      requestedSchema: { type: "object", properties: {} },
      _meta: { codex_approval_kind: "mcp_tool_call", tool_name: "takeform_snapshot", tool_params: {} }
    }
  };
  assert.equal(policy({ ...base, params: { ...base.params, turnId: "turn-2" } }), null);
  assert.equal(policy({ ...base, params: { ...base.params, _meta: { ...base.params._meta, tool_name: "other" } } }), null);
  assert.equal(policy({ ...base, params: { ...base.params, _meta: { ...base.params._meta, tool_params: { extra: true } } } }), null);
});
