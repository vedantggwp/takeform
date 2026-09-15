import readline from "node:readline";
import { appendFileSync } from "node:fs";
import { createServer } from "node:net";
import { ProposalStore, ProtocolError } from "./protocol.mjs";

const store = new ProposalStore();

const tools = [
  {
    name: "takeform_snapshot",
    description: "Read the generated three-scene project at its current revision. This does not change the project.",
    inputSchema: { type: "object", additionalProperties: false, properties: {} }
  },
  {
    name: "takeform_propose_edit",
    description: "Store one version-bound edit proposal. This creates a pending proposal and does not change the project. A test creator must accept it separately.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["expectedRevision", "sceneID", "replacementText", "commandID"],
      properties: {
        expectedRevision: { type: "integer", minimum: 1 },
        sceneID: { type: "string", enum: ["scene-1", "scene-2", "scene-3"] },
        replacementText: { type: "string", minLength: 1, maxLength: 160 },
        commandID: { type: "string", pattern: "^proposal-[a-z0-9-]{8,64}$" }
      }
    }
  }
];

function record(type, details = {}) {
  if (!eventPath) return;
  appendFileSync(eventPath, `${JSON.stringify({ type, ...details })}\n`);
}

function respond(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function failure(id, error) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32602, message: error.message, data: { code: error.code ?? "invalid_request" } } })}\n`);
}

function text(result) {
  return { content: [{ type: "text", text: JSON.stringify(result) }], structuredContent: result };
}

function handle(request) {
  if (request.method === "initialize") {
    return { protocolVersion: request.params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "takeform-proof", version: "0.2.0" } };
  }
  if (request.method === "tools/list") {
    record("tools_listed", { names: tools.map((tool) => tool.name) });
    return { tools };
  }
  if (request.method === "tools/call") {
    if (request.params?.name === "takeform_snapshot") {
      record("snapshot_read", { tool: "takeform_snapshot", revision: store.getSnapshot().revision });
      return text(store.getSnapshot());
    }
    if (request.params?.name === "takeform_propose_edit") {
      const result = store.submit(request.params.arguments);
      record("proposal_submitted", { tool: "takeform_propose_edit", commandID: result.proposal.commandID, expectedRevision: result.proposal.expectedRevision, sceneID: result.proposal.sceneID });
      return text(result);
    }
    throw new ProtocolError("unknown_tool", "Tool is not advertised by this proof server.");
  }
  throw new ProtocolError("method_not_found", "Method is not supported by this proof server.");
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  try {
    const request = JSON.parse(line);
    if (!Object.hasOwn(request, "id")) return;
    respond(request.id, handle(request));
  } catch (error) {
    const id = (() => { try { return JSON.parse(line).id ?? null; } catch { return null; } })();
    failure(id, error);
  }
});

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

const controlSocket = argument("--control-socket") ?? process.env.TAKEFORM_PROOF_CONTROL_SOCKET;
const eventPath = argument("--events") ?? process.env.TAKEFORM_PROOF_EVENTS;
let controlServer;
const controlConnections = new Set();
let stopping = false;
record("server_started", { nodeVersion: process.version });

function controlResult(request) {
  if (request.action === "inspect") {
    return { snapshot: store.getSnapshot(), pending: store.getPending() };
  }
  if (request.action === "accept") {
    return store.accept(request.commandID);
  }
  throw new ProtocolError("unknown_control_action", "The control action is not supported.");
}

if (controlSocket) {
  controlServer = createServer((connection) => {
    controlConnections.add(connection);
    connection.once("close", () => controlConnections.delete(connection));
    const lines = readline.createInterface({ input: connection, crlfDelay: Infinity });
    lines.once("line", (line) => {
      try {
        connection.end(`${JSON.stringify({ ok: true, result: controlResult(JSON.parse(line)) })}\n`);
      } catch (error) {
        connection.end(`${JSON.stringify({ ok: false, error: { code: error.code ?? "invalid_request", message: error.message } })}\n`);
      }
    });
  });
  controlServer.listen(controlSocket);
}

function shutdown() {
  if (stopping) return;
  stopping = true;
  for (const connection of controlConnections) connection.destroy();
  if (controlServer) controlServer.close(() => process.exit(0));
  else process.exit(0);
}

input.once("close", shutdown);
process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
