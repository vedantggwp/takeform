import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import readline from "node:readline";

const codexIndex = process.argv.indexOf("--codex");
const codexCommand = codexIndex === -1 ? (process.env.CODEX_BIN ?? "codex") : process.argv[codexIndex + 1];
const child = spawn(codexCommand, ["app-server", "-c", "mcp_servers.required_failure.command=\"/usr/bin/false\"", "-c", "mcp_servers.required_failure.required=true", "--stdio"], { stdio: ["pipe", "pipe", "pipe"] });
const pending = new Map();
let nextID = 0;
let terminalError;

function rejectPending(error) {
  terminalError = error;
  for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
  pending.clear();
}

child.once("error", rejectPending);
child.once("exit", (code, signal) => rejectPending(new Error(`Codex app-server exited (${code ?? signal}).`)));
readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", (line) => {
  const message = JSON.parse(line);
  if (!Object.hasOwn(message, "id")) return;
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  clearTimeout(request.timer);
  request.resolve(message.error ? { error: message.error } : { result: message.result });
});

function request(method, params, timeoutMs = 15_000) {
  if (terminalError) return Promise.reject(terminalError);
  const id = nextID++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timed out waiting for ${method}.`)); }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(`${JSON.stringify({ method, id, params })}\n`);
  });
}

async function stop() {
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  await Promise.race([new Promise((resolve) => child.once("exit", resolve)), new Promise((resolve) => setTimeout(resolve, 2_000))]);
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
}

try {
  assert.ok((await request("initialize", { clientInfo: { name: "takeform-proof", title: "Takeform proof", version: "0.2.0" } })).result);
  child.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
  const started = await request("thread/start", { model: "gpt-5.6-terra", ephemeral: true, sandbox: "read-only" });
  assert.ok(started.error, "thread/start succeeded despite a required server that exits immediately.");
  const message = started.error.message ?? "";
  assert.match(message, /required_failure/i, "thread/start failed without naming required_failure.");
  assert.match(message, /MCP|broken pipe|initialize/i, "thread/start did not report the required MCP startup failure.");
  process.stdout.write(`${JSON.stringify({ requiredServerFailure: true, server: "required_failure", modelTurnStarted: false, failure: "named_required_mcp_startup_failure" })}\n`);
} finally {
  await stop();
}
