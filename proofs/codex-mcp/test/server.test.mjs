import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createConnection } from "node:net";
import readline from "node:readline";
import test from "node:test";

function control(socketPath, message) {
  return new Promise((resolve, reject) => {
    const connection = createConnection(socketPath);
    let body = "";
    const timer = setTimeout(() => { connection.destroy(); reject(new Error("Control timeout.")); }, 2_000);
    connection.once("error", (error) => { clearTimeout(timer); reject(error); });
    connection.on("data", (chunk) => { body += chunk.toString(); });
    connection.once("end", () => { clearTimeout(timer); resolve(JSON.parse(body)); });
    connection.once("connect", () => connection.end(`${JSON.stringify(message)}\n`));
  });
}

test("one server store spans MCP proposal and creator acceptance", async () => {
  const attemptDir = mkdtempSync("/private/tmp/tfmcp-test-");
  const socketPath = `${attemptDir}/creator.sock`;
  const server = spawn(process.execPath, ["src/server.mjs", "--control-socket", socketPath], { cwd: process.cwd(), stdio: ["pipe", "pipe", "pipe"] });
  const pending = new Map();
  let childFailure;
  readline.createInterface({ input: server.stdout, crlfDelay: Infinity }).on("line", (line) => {
    const message = JSON.parse(line);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    clearTimeout(waiter.timer);
    waiter.resolve(message);
  });
  const rejectAll = (error) => {
    childFailure = error;
    for (const waiter of pending.values()) { clearTimeout(waiter.timer); waiter.reject(error); }
    pending.clear();
  };
  server.once("error", rejectAll);
  server.once("exit", (code, signal) => rejectAll(new Error(`Server exited (${code ?? signal}).`)));
  const request = (id, method, params) => new Promise((resolve, reject) => {
    if (childFailure) { reject(childFailure); return; }
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Request ${id} timed out.`)); }, 2_000);
    pending.set(id, { resolve, reject, timer });
    server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
  const stop = async () => {
    if (server.exitCode === null && server.signalCode === null) server.kill("SIGTERM");
    await Promise.race([new Promise((resolve) => server.once("exit", resolve)), new Promise((resolve) => setTimeout(resolve, 2_000))]);
    if (server.exitCode === null && server.signalCode === null) server.kill("SIGKILL");
  };

  try {
    assert.equal((await request(1, "initialize", { protocolVersion: "2025-06-18" })).result.serverInfo.name, "takeform-proof");
    assert.deepEqual((await request(2, "tools/list", {})).result.tools.map((tool) => tool.name), ["takeform_snapshot", "takeform_propose_edit"]);
    const proposal = { expectedRevision: 1, sceneID: "scene-2", replacementText: "Show the decision that changes the result.", commandID: "proposal-frame-0001" };
    assert.equal(JSON.parse((await request(3, "tools/call", { name: "takeform_propose_edit", arguments: proposal })).result.content[0].text).revision, 1);
    assert.equal((await control(socketPath, { action: "inspect" })).result.snapshot.revision, 1);
    assert.equal((await control(socketPath, { action: "accept", commandID: proposal.commandID })).result.revision, 2);
    assert.equal(JSON.parse((await request(4, "tools/call", { name: "takeform_snapshot", arguments: {} })).result.content[0].text).revision, 2);
  } finally {
    await stop();
    rmSync(attemptDir, { recursive: true, force: true });
  }
});

test("stdio EOF shuts down the owned creator socket", async () => {
  const attemptDir = mkdtempSync("/private/tmp/tfmcp-eof-");
  const socketPath = `${attemptDir}/creator.sock`;
  const server = spawn(process.execPath, ["src/server.mjs", "--control-socket", socketPath], { cwd: process.cwd(), stdio: ["pipe", "pipe", "pipe"] });
  const response = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Initialization timeout.")), 2_000);
    readline.createInterface({ input: server.stdout, crlfDelay: Infinity }).once("line", (line) => {
      clearTimeout(timer);
      resolve(JSON.parse(line));
    });
  });
  const exited = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Server did not exit after stdio EOF.")), 2_000);
    server.once("exit", (code, signal) => { clearTimeout(timer); resolve({ code, signal }); });
  });

  try {
    server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })}\n`);
    assert.equal((await response).result.serverInfo.name, "takeform-proof");
    server.stdin.end();
    assert.deepEqual(await exited, { code: 0, signal: null });
    await assert.rejects(control(socketPath, { action: "inspect" }));
  } finally {
    if (server.exitCode === null && server.signalCode === null) server.kill("SIGKILL");
    rmSync(attemptDir, { recursive: true, force: true });
  }
});
