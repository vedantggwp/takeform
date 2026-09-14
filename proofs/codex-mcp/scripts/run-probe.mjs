import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { AppServer, mcpToolApprovalPolicy } from "../src/app-server-client.mjs";

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

function errorSummary(error, stderr) {
  const message = String(error?.message ?? "unknown failure");
  return {
    category: message.includes("Timed out") ? "timeout" : error?.rpcError ? "rpc_error" : "assertion_or_runtime_error",
    code: error?.rpcError?.code ?? error?.code ?? null,
    processCategory: !message.includes("exited before") ? null
      : /config|toml/i.test(stderr) ? "configuration"
        : /permission|operation not permitted/i.test(stderr) ? "filesystem_permission" : null
  };
}

async function listAll(app, method, params) {
  const data = [];
  let cursor;
  do {
    const page = await app.request(method, { ...params, ...(cursor ? { cursor } : {}) });
    data.push(...page.data);
    cursor = page.nextCursor;
  } while (cursor);
  return data;
}

const runTurn = process.argv.includes("--turn");
const receiptPath = option("--receipt");
const codexCommand = option("--codex") ?? process.env.CODEX_BIN ?? "codex";
const disabledServers = options("--disable-server");
const disabledHTTPServers = options("--disable-http-server");
const maskedServers = options("--mask-server");
const allDisabledServers = [...disabledServers, ...disabledHTTPServers, ...maskedServers];
assert.ok(allDisabledServers.every((name) => /^[a-zA-Z0-9_.-]+$/.test(name)), "Invalid MCP server name supplied for disablement.");
assert.equal(new Set(allDisabledServers).size, allDisabledServers.length, "Each disabled MCP server must be listed once.");
assert.ok(!allDisabledServers.includes("takeform"), "The Takeform proof server cannot be disabled.");
const proofRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const serverPath = join(proofRoot, "src", "server.mjs");
const attemptDir = mkdtempSync("/private/tmp/tfmcp-");
const controlSocket = join(attemptDir, "creator.sock");
const eventPath = join(attemptDir, "mcp-events.jsonl");
const appServerArgs = [
  "app-server",
  ...[...disabledServers, ...disabledHTTPServers].flatMap((name) => ["-c", `mcp_servers.${name}.enabled=false`]),
  ...maskedServers.flatMap((name) => ["-c", `mcp_servers.${name}={command="false",enabled=false}`]),
  "-c", `mcp_servers.takeform.command=${JSON.stringify(process.execPath)}`,
  "-c", `mcp_servers.takeform.args=[${[
    serverPath, "--control-socket", controlSocket, "--events", eventPath
  ].map((value) => JSON.stringify(value)).join(",")}]`,
  "-c", "mcp_servers.takeform.enabled=true",
  "-c", "mcp_servers.takeform.required=true",
  "-c", "mcp_servers.takeform.startup_timeout_sec=10",
  "-c", "mcp_servers.takeform.tool_timeout_sec=10",
  "--stdio"
];
let turnId = null;
let threadId = null;
const app = new AppServer(codexCommand, appServerArgs, {
  serverRequestPolicy: mcpToolApprovalPolicy({
    serverName: "takeform",
    calls: [
      { tool: "takeform_snapshot", arguments: {} },
      { tool: "takeform_propose_edit", arguments: PROPOSAL }
    ],
    getActiveTurn: () => ({ threadId, turnId })
  })
});
const phases = { processStartedAt: new Date().toISOString() };
let receipt = {
  kind: runTurn ? "real_model_round_trip" : "no_model_preflight",
  codexVersion: "0.154.0",
  modelTurnStarted: false,
  ephemeral: true,
  sandbox: "read-only",
  configuration: "app-server caller-owned mcp_servers override",
  turnStartReturned: false,
  phases
};
let modelEventCursor = null;

try {
  await app.request("initialize", { clientInfo: { name: "takeform-proof", title: "Takeform proof", version: "0.2.0" } });
  app.notify("initialized");
  phases.initializedAt = new Date().toISOString();

  const catalog = await listAll(app, "model/list", { includeHidden: false, limit: 100 });
  const terra = catalog.find((entry) => entry.id === "gpt-5.6-terra" || entry.model === "gpt-5.6-terra");
  assert.ok(terra, "The installed model catalog does not advertise gpt-5.6-terra.");
  const model = terra.id ?? terra.model;

  const statuses = await listAll(app, "mcpServerStatus/list", { detail: "toolsAndAuthOnly", limit: 20 });
  const unrelated = statuses.filter((server) => server.name !== "takeform");
  assert.ok(unrelated.every((server) => Object.keys(server.tools).length === 0), "An unrelated MCP server exposed tools.");
  const takeform = statuses.find((server) => server.name === "takeform");
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
  threadId = thread.id;
  assert.ok(threadId, "thread/start did not return a thread id.");

  const firstSnapshot = parseTextResult(await app.request("mcpServer/tool/call", {
    threadId, server: "takeform", tool: "takeform_snapshot", arguments: {}
  }));
  assert.equal(firstSnapshot.revision, 1);

  receipt = {
    ...receipt,
    model,
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
  phases.preflightCompletedAt = new Date().toISOString();

  if (runTurn) {
    modelEventCursor = readEvents(eventPath).length;
    const prompt = `Call takeform_snapshot. Then call takeform_propose_edit exactly once with ${JSON.stringify(PROPOSAL)}. Do not call any other tool. After the proposal, reply only: Proposed.`;
    receipt.modelTurnStarted = true;
    phases.turnStartRequestedAt = new Date().toISOString();
    const turnStarted = await app.request("turn/start", {
      threadId,
      effort: "low",
      summary: "none",
      sandboxPolicy: { type: "readOnly", networkAccess: false },
      input: [{ type: "text", text: prompt }]
    }, 30_000);
    receipt.turnStartReturned = true;
    phases.turnStartReturnedAt = new Date().toISOString();
    turnId = turnStarted.turn?.id ?? turnStarted.id;
    receipt.turn = { id: turnId, status: "started" };
    const completed = await app.waitFor((message) => message.method === "turn/completed" && message.params?.turn?.id === turnId, 120_000);
    phases.turnCompletedAt = new Date().toISOString();
    receipt.turn.status = completed.params.turn.status;
    receipt.turn.errorCode = completed.params.turn.error?.code ?? null;
    assert.equal(completed.params.turn.status, "completed", completed.params.turn.error?.message);

    const events = readEvents(eventPath).slice(modelEventCursor);
    assert.deepEqual(events.map((event) => ({ origin: "model", type: event.type, tool: event.tool })), [
      { origin: "model", type: "snapshot_read", tool: "takeform_snapshot" },
      { origin: "model", type: "proposal_submitted", tool: "takeform_propose_edit" }
    ], "The model must issue exactly one snapshot followed by exactly one proposal.");
    assert.equal(events[1].commandID, PROPOSAL.commandID, "The model did not submit the specified proposal.");

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
      modelToolEvents: events.map((event) => ({ origin: "model", ...event }))
    };
    receipt.tokenUsage = usage;
    receipt.diagnostics = app.diagnostics();
    receipt.result = "passed";
  } else {
    receipt.diagnostics = app.diagnostics();
    receipt.result = "passed_before_model_turn";
  }
} catch (error) {
  phases.failedAt = new Date().toISOString();
  receipt.result = "failed";
  receipt.failure = errorSummary(error, app.stderr);
  if (!receipt.turn || receipt.turn.status === "started") {
    receipt.turn = { id: turnId, status: turnId ? "completion_not_observed" : "not_started" };
  }
  if (modelEventCursor !== null) {
    receipt.modelToolEvents = readEvents(eventPath).slice(modelEventCursor).map((event) => event.type);
    receipt.tokenUsage = app.notifications("thread/tokenUsage/updated").at(-1)?.params?.tokenUsage?.last ?? null;
  }
  receipt.diagnostics = app.diagnostics();
  process.exitCode = 1;
} finally {
  receipt.processExit = await app.close();
  phases.processReapedAt = new Date().toISOString();
  receipt.terminalScratchInventory = [eventPath, controlSocket]
    .filter(existsSync)
    .map((path) => ({ name: basename(path), bytes: statSync(path).size }));
  if (receiptPath) writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
  else process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  rmSync(attemptDir, { recursive: true, force: true });
}
