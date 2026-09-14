import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { basename, dirname, join, relative, resolve } from "node:path";
import readline from "node:readline";

const REQUIRED_TOOLS = ["takeform_propose_edit", "takeform_snapshot"];
const PROPOSAL = Object.freeze({
  expectedRevision: 1,
  sceneID: "scene-2",
  replacementText: "Show the decision that changes the result.",
  commandID: "proposal-live-20260914"
});

function option(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function options(name) {
  return process.argv.flatMap((value, index) => value === name ? [process.argv[index + 1]] : []);
}

class AppServer {
  #child;
  #nextID = 0;
  #pending = new Map();
  #notifications = [];
  #waiters = [];
  stderr = "";

  constructor(command, args) {
    this.#child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.#child.stderr.on("data", (chunk) => { this.stderr += chunk.toString(); });
    const lines = readline.createInterface({ input: this.#child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => this.#receive(line));
    this.#child.once("error", (error) => this.#rejectAll(error));
    this.#child.once("exit", (code, signal) => {
      this.#rejectAll(new Error(`Codex app-server exited before the request completed (${code ?? signal}).`));
    });
  }

  #receive(line) {
    let message;
    try { message = JSON.parse(line); }
    catch (error) { this.#rejectAll(new Error(`Codex app-server emitted invalid JSON: ${error.message}`)); return; }
    if (Object.hasOwn(message, "id")) {
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        const error = new Error(message.error.message ?? "App-server request failed.");
        error.rpcError = message.error;
        pending.reject(error);
      } else pending.resolve(message.result);
      return;
    }
    this.#notifications.push(message);
    for (const waiter of [...this.#waiters]) {
      if (waiter.predicate(message)) {
        this.#waiters.splice(this.#waiters.indexOf(waiter), 1);
        clearTimeout(waiter.timer);
        waiter.resolve(message);
      }
    }
  }

  #rejectAll(error) {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
    for (const waiter of this.#waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.#waiters = [];
  }

  request(method, params, timeoutMs = 15_000) {
    const id = this.#nextID++;
    return new Promise((resolveRequest, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`Timed out waiting for ${method}.`));
      }, timeoutMs);
      this.#pending.set(id, { resolve: resolveRequest, reject, timer });
      this.#child.stdin.write(`${JSON.stringify({ method, id, params })}\n`);
    });
  }

  notify(method, params = {}) {
    this.#child.stdin.write(`${JSON.stringify({ method, params })}\n`);
  }

  waitFor(predicate, timeoutMs = 60_000) {
    const prior = this.#notifications.find(predicate);
    if (prior) return Promise.resolve(prior);
    return new Promise((resolveWait, reject) => {
      const waiter = { predicate, resolve: resolveWait, reject };
      waiter.timer = setTimeout(() => {
        this.#waiters.splice(this.#waiters.indexOf(waiter), 1);
        reject(new Error("Timed out waiting for app-server notification."));
      }, timeoutMs);
      this.#waiters.push(waiter);
    });
  }

  notifications(method) {
    return this.#notifications.filter((message) => message.method === method);
  }

  async close() {
    if (this.#child.exitCode !== null || this.#child.signalCode !== null) return;
    this.#child.kill("SIGTERM");
    await Promise.race([
      new Promise((resolveExit) => this.#child.once("exit", resolveExit)),
      new Promise((resolveTimeout) => setTimeout(resolveTimeout, 2_000))
    ]);
    if (this.#child.exitCode === null && this.#child.signalCode === null) this.#child.kill("SIGKILL");
  }
}

function parseTextResult(result) {
  if (result.structuredContent) return result.structuredContent;
  const text = result.content?.find((item) => item.type === "text")?.text;
  return text ? JSON.parse(text) : undefined;
}

function control(socketPath, request, timeoutMs = 5_000) {
  return new Promise((resolveControl, reject) => {
    const connection = createConnection(socketPath);
    let body = "";
    const timer = setTimeout(() => {
      connection.destroy();
      reject(new Error("Timed out waiting for the creator control channel."));
    }, timeoutMs);
    connection.once("error", (error) => { clearTimeout(timer); reject(error); });
    connection.on("data", (chunk) => { body += chunk.toString(); });
    connection.once("end", () => {
      clearTimeout(timer);
      try { resolveControl(JSON.parse(body)); }
      catch (error) { reject(new Error(`Control channel emitted invalid JSON: ${error.message}`)); }
    });
    connection.once("connect", () => connection.end(`${JSON.stringify(request)}\n`));
  });
}

function sourceLabel(source, proofRoot) {
  const resolved = resolve(source);
  const rel = relative(proofRoot, resolved);
  if (rel && !rel.startsWith("..")) return `<proof-root>/${rel}`;
  return `<external>/${basename(resolved)}`;
}

function readEvents(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

const runTurn = process.argv.includes("--turn");
const receiptPath = option("--receipt");
const codexCommand = option("--codex") ?? process.env.CODEX_BIN ?? "codex";
const disabledServers = options("--disable-server");
const disabledHTTPServers = options("--disable-http-server");
const allDisabledServers = [...disabledServers, ...disabledHTTPServers];
assert.ok(allDisabledServers.every((name) => /^[a-zA-Z0-9_.-]+$/.test(name)), "Invalid MCP server name supplied for disablement.");
assert.equal(new Set(allDisabledServers).size, allDisabledServers.length, "Each disabled MCP server must be listed once.");
assert.ok(!allDisabledServers.includes("takeform"), "The Takeform proof server cannot be disabled.");
const proofRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const serverPath = join(proofRoot, "src", "server.mjs");
const attemptDir = mkdtempSync("/private/tmp/tfmcp-");
const controlSocket = join(attemptDir, "creator.sock");
const eventPath = join(attemptDir, "mcp-events.jsonl");
const disabledConfig = [
  ...disabledServers.map((name) => `${JSON.stringify(name)}={command="false",enabled=false}`),
  ...disabledHTTPServers.map((name) => `${JSON.stringify(name)}={url="http://127.0.0.1",enabled=false}`)
];
const mcpConfig = `mcp_servers={${[...disabledConfig, `takeform={command=${JSON.stringify(process.execPath)},args=[${[
  serverPath, "--control-socket", controlSocket, "--events", eventPath
].map((value) => JSON.stringify(value)).join(",")}],required=true,startup_timeout_sec=10,tool_timeout_sec=10}`].join(",")}}`;
const app = new AppServer(codexCommand, ["app-server", "-c", mcpConfig, "--stdio"]);
let receipt;

try {
  await app.request("initialize", { clientInfo: { name: "takeform-proof", title: "Takeform proof", version: "0.2.0" } });
  app.notify("initialized");

  const catalog = await app.request("model/list", { includeHidden: false, limit: 100 });
  const terra = catalog.data.find((entry) => entry.id === "gpt-5.6-terra" || entry.model === "gpt-5.6-terra");
  assert.ok(terra, "The installed model catalog does not advertise gpt-5.6-terra.");
  const model = terra.id ?? terra.model;

  const statuses = await app.request("mcpServerStatus/list", { detail: "toolsAndAuthOnly", limit: 20 });
  const unrelated = statuses.data.filter((server) => server.name !== "takeform");
  assert.ok(unrelated.every((server) => Object.keys(server.tools).length === 0), "An unrelated MCP server exposed tools.");
  const takeform = statuses.data.find((server) => server.name === "takeform");
  assert.ok(takeform, "The Takeform MCP server is absent from the catalog.");
  const toolNames = Object.values(takeform.tools).map((tool) => tool.name).sort();
  assert.deepEqual(toolNames, REQUIRED_TOOLS, `The required Takeform tools were not discovered (${takeform.runtimeStatus}: ${takeform.toolsError ?? "no error"}).`);
  assert.equal(takeform.toolsError ?? null, null);

  const started = await app.request("thread/start", {
    cwd: proofRoot,
    model,
    ephemeral: true,
    sandbox: "read-only",
    baseInstructions: "You are a narrow editing agent. Use only the tool calls required by the developer instruction.",
    developerInstructions: "Read the generated Takeform snapshot, submit the specified proposal, and make no direct mutation."
  });
  const thread = started.thread ?? started;
  const threadId = thread.id;
  assert.ok(threadId, "thread/start did not return a thread id.");

  const firstSnapshot = parseTextResult(await app.request("mcpServer/tool/call", {
    threadId, server: "takeform", tool: "takeform_snapshot", arguments: {}
  }));
  assert.equal(firstSnapshot.revision, 1);

  receipt = {
    kind: runTurn ? "real_model_round_trip" : "no_model_preflight",
    codexVersion: "0.154.0",
    model,
    modelTurnStarted: runTurn,
    ephemeral: true,
    sandbox: "read-only",
    configuration: "app-server caller-owned mcp_servers override",
    mcpServers: [takeform.name],
    unrelatedServers: { count: unrelated.length, configuredForInvocation: "disabled", exposedTools: 0 },
    tools: toolNames,
    instructionSources: (thread.instructionSources ?? []).map((source) => sourceLabel(source, proofRoot)),
    returnedSettings: {
      model: thread.model ?? model,
      modelProvider: thread.modelProvider ?? null,
      reasoningEffort: thread.reasoningEffort ?? null,
      approvalPolicy: thread.approvalPolicy ?? null
    },
    initialSnapshot: firstSnapshot
  };

  if (runTurn) {
    const prompt = `Call takeform_snapshot. Then call takeform_propose_edit exactly once with ${JSON.stringify(PROPOSAL)}. Do not call any other tool. After the proposal, reply only: Proposed.`;
    const turnStarted = await app.request("turn/start", {
      threadId,
      effort: "low",
      summary: "none",
      sandboxPolicy: { type: "readOnly", networkAccess: false },
      input: [{ type: "text", text: prompt }]
    }, 30_000);
    const turnId = turnStarted.turn?.id ?? turnStarted.id;
    const completed = await app.waitFor((message) => message.method === "turn/completed" && message.params?.turn?.id === turnId, 90_000);
    assert.equal(completed.params.turn.status, "completed", completed.params.turn.error?.message);

    const events = readEvents(eventPath);
    assert.ok(events.some((event) => event.type === "snapshot_read"), "The model did not read the snapshot.");
    assert.ok(events.some((event) => event.type === "proposal_submitted" && event.commandID === PROPOSAL.commandID), "The model did not submit the specified proposal.");

    const inspected = await control(controlSocket, { action: "inspect" });
    assert.equal(inspected.ok, true);
    assert.deepEqual(inspected.result.pending, [PROPOSAL]);
    assert.equal(inspected.result.snapshot.revision, 1);

    const beforeAcceptance = parseTextResult(await app.request("mcpServer/tool/call", {
      threadId, server: "takeform", tool: "takeform_snapshot", arguments: {}
    }));
    assert.equal(beforeAcceptance.revision, 1);

    const accepted = await control(controlSocket, { action: "accept", commandID: PROPOSAL.commandID });
    assert.deepEqual(accepted, { ok: true, result: { commandID: PROPOSAL.commandID, revision: 2, state: "accepted" } });
    const afterAcceptance = parseTextResult(await app.request("mcpServer/tool/call", {
      threadId, server: "takeform", tool: "takeform_snapshot", arguments: {}
    }));
    assert.equal(afterAcceptance.revision, 2);
    assert.equal(afterAcceptance.scenes[1].sentence, PROPOSAL.replacementText);

    const duplicate = await control(controlSocket, { action: "accept", commandID: PROPOSAL.commandID });
    assert.deepEqual(duplicate, accepted);

    const stale = { ...PROPOSAL, commandID: "proposal-stale-20260914" };
    parseTextResult(await app.request("mcpServer/tool/call", {
      threadId, server: "takeform", tool: "takeform_propose_edit", arguments: stale
    }));
    const staleResult = await control(controlSocket, { action: "accept", commandID: stale.commandID });
    assert.equal(staleResult.ok, false);
    assert.equal(staleResult.error.code, "stale_proposal");

    let malformedCode;
    try {
      const malformed = await app.request("mcpServer/tool/call", {
        threadId,
        server: "takeform",
        tool: "takeform_propose_edit",
        arguments: { ...PROPOSAL, commandID: "proposal-empty-20260914", replacementText: "   " }
      });
      malformedCode = malformed.isError ? "invalid_proposal" : null;
    } catch (error) {
      malformedCode = error.rpcError?.data?.code ?? (error.message.includes("replacementText") ? "invalid_proposal" : null);
    }
    assert.equal(malformedCode, "invalid_proposal");

    const usageMessages = app.notifications("thread/tokenUsage/updated");
    const usage = usageMessages.at(-1)?.params?.tokenUsage?.last ?? null;
    receipt.roundTrip = {
      proposal: PROPOSAL,
      preAcceptRevision: beforeAcceptance.revision,
      acceptance: accepted.result,
      postAcceptRevision: afterAcceptance.revision,
      duplicateAcceptance: duplicate.result,
      staleRejection: staleResult.error.code,
      malformedRejection: malformedCode,
      modelToolEvents: events.filter((event) => ["snapshot_read", "proposal_submitted"].includes(event.type))
    };
    receipt.tokenUsage = usage;
    receipt.result = "passed";
  } else {
    receipt.result = "passed_before_model_turn";
  }
} catch (error) {
  process.stderr.write(`${JSON.stringify({ serverEvents: readEvents(eventPath).map((event) => event.type) })}\n`);
  throw error;
} finally {
  await app.close();
  if (receipt) {
    receipt.terminalScratchInventory = [eventPath, controlSocket]
      .filter(existsSync)
      .map((path) => ({ name: basename(path), bytes: statSync(path).size }));
    if (receiptPath) writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
    else process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  }
  rmSync(attemptDir, { recursive: true, force: true });
}
