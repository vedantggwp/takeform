import readline from "node:readline";
import { appendFileSync } from "node:fs";
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
  if (!process.env.TAKEFORM_PROOF_EVENTS) return;
  appendFileSync(process.env.TAKEFORM_PROOF_EVENTS, `${JSON.stringify({ type, ...details })}\n`);
}

function respond(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function failure(id, error) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32602, message: error.message, data: { code: error.code ?? "invalid_request" } } })}\n`);
}

function text(result) {
  return { content: [{ type: "text", text: JSON.stringify(result) }] };
}

function handle(request) {
  if (request.method === "initialize") {
    return { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "takeform-proof", version: "0.1.0" } };
  }
  if (request.method === "tools/list") {
    record("tools_listed", { names: tools.map((tool) => tool.name) });
    return { tools };
  }
  if (request.method === "tools/call") {
    if (request.params?.name === "takeform_snapshot") {
      record("snapshot_read", { revision: store.getSnapshot().revision });
      return text(store.getSnapshot());
    }
    if (request.params?.name === "takeform_propose_edit") {
      const result = store.submit(request.params.arguments);
      record("proposal_submitted", { commandID: result.proposal.commandID, expectedRevision: result.proposal.expectedRevision, sceneID: result.proposal.sceneID });
      return text(result);
    }
    throw new ProtocolError("unknown_tool", "Tool is not advertised by this proof server.");
  }
  throw new ProtocolError("method_not_found", "Method is not supported by this proof server.");
}

readline.createInterface({ input: process.stdin, crlfDelay: Infinity }).on("line", (line) => {
  try {
    const request = JSON.parse(line);
    if (!Object.hasOwn(request, "id")) return;
    respond(request.id, handle(request));
  } catch (error) {
    const id = (() => { try { return JSON.parse(line).id ?? null; } catch { return null; } })();
    failure(id, error);
  }
});
