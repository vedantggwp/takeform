import { spawn } from "node:child_process";
import readline from "node:readline";

const codex = spawn("/opt/homebrew/bin/codex", [
  "app-server",
  "-c", "mcp_servers.required_failure.command=\"/usr/bin/false\"",
  "-c", "mcp_servers.required_failure.required=true"
], { stdio: ["pipe", "pipe", "pipe"] });

const lines = readline.createInterface({ input: codex.stdout, crlfDelay: Infinity });
const stderr = [];
codex.stderr.on("data", (chunk) => stderr.push(chunk.toString()));

function send(message) {
  codex.stdin.write(`${JSON.stringify(message)}\n`);
}

const timeout = setTimeout(() => {
  codex.kill();
  throw new Error("Timed out waiting for required MCP startup failure.");
}, 15_000);

lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.id === 0) {
    send({ method: "initialized", params: {} });
    send({ method: "thread/start", id: 1, params: { model: "gpt-5.6-terra", ephemeral: true } });
    return;
  }
  if (message.id === 1) {
    clearTimeout(timeout);
    codex.kill();
    const result = { requiredServerFailure: Boolean(message.error), error: message.error?.message ?? null, stderr: stderr.join("").trim() };
    if (!result.requiredServerFailure) throw new Error("thread/start succeeded despite a required server that exits immediately.");
    process.stdout.write(`${JSON.stringify(result)}\n`);
  }
});

send({ method: "initialize", id: 0, params: { clientInfo: { name: "takeform-proof", title: "Takeform proof", version: "0.1.0" } } });
