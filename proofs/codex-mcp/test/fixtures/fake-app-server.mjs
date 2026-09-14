import readline from "node:readline";

let serverRequestAnswered = false;
let unsupportedRequestAnswered = false;
const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);

readline.createInterface({ input: process.stdin, crlfDelay: Infinity }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ id: message.id, result: {} });
    send(process.argv.includes("--takeform-approval")
      ? {
          id: "server-1",
          method: "mcpServer/elicitation/request",
          params: {
            serverName: "takeform",
            threadId: "fake-thread",
            turnId: "fake-turn",
            mode: "form",
            message: "fake",
            requestedSchema: { type: "object", properties: {} },
            _meta: { codex_approval_kind: "mcp_tool_call", tool_name: "takeform_snapshot", tool_params: {} }
          }
        }
      : { id: "server-1", method: "mcpServer/elicitation/request", params: { message: "fake" } });
    return;
  }
  if (message.id === "server-1") {
    serverRequestAnswered = process.argv.includes("--takeform-approval")
      ? message.result?.action === "accept" && Object.keys(message.result.content).length === 0
      : message.result?.action === "decline";
    send({ id: "server-2", method: "item/tool/call", params: { tool: "outside-proof" } });
    return;
  }
  if (message.id === "server-2") {
    unsupportedRequestAnswered = message.error?.code === -32601;
    send({ method: "serverRequest/resolved", params: {} });
    return;
  }
  if (message.method === "turn/start") {
    if (!serverRequestAnswered || !unsupportedRequestAnswered) {
      send({ id: message.id, error: { code: -32001, message: "server request was not answered" } });
      return;
    }
    send({ id: message.id, result: { turn: { id: "fake-turn" } } });
    send({ method: "turn/completed", params: { turn: { id: "fake-turn", status: "failed", error: { code: "fake_failure" } } } });
  }
});

process.on("SIGTERM", () => {
  if (!process.argv.includes("--ignore-term")) process.exit(0);
});
