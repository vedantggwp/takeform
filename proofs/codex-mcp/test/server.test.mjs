import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import readline from "node:readline";
import test from "node:test";

test("the stdio server frames discovery and a pending proposal", async () => {
  const server = spawn(process.execPath, ["src/server.mjs"], { cwd: process.cwd(), stdio: ["pipe", "pipe", "pipe"] });
  const messages = [];
  const lines = readline.createInterface({ input: server.stdout, crlfDelay: Infinity });
  lines.on("line", (line) => messages.push(JSON.parse(line)));
  const request = (id, method, params) => {
    server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  };
  const waitFor = async (id) => {
    while (!messages.some((message) => message.id === id)) await new Promise((resolve) => setTimeout(resolve, 5));
    return messages.find((message) => message.id === id);
  };

  try {
    request(1, "initialize", { clientInfo: { name: "test", version: "0.1.0" } });
    assert.equal((await waitFor(1)).result.serverInfo.name, "takeform-proof");
    request(2, "tools/list", {});
    assert.deepEqual((await waitFor(2)).result.tools.map((tool) => tool.name), ["takeform_snapshot", "takeform_propose_edit"]);
    request(3, "tools/call", { name: "takeform_propose_edit", arguments: { expectedRevision: 1, sceneID: "scene-2", replacementText: "Show the decision that changes the result.", commandID: "proposal-frame-0001" } });
    const result = JSON.parse((await waitFor(3)).result.content[0].text);
    assert.equal(result.state, "pending");
    assert.equal(result.revision, 1);
  } finally {
    server.kill();
  }
});
