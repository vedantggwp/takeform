import { spawn } from "node:child_process";
import { isDeepStrictEqual } from "node:util";
import readline from "node:readline";

const REQUEST_METHODS = new Set([
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/tool/requestUserInput",
  "mcpServer/elicitation/request",
  "item/permissions/requestApproval",
  "item/tool/call",
  "account/chatgptAuthTokens/refresh",
  "attestation/generate",
  "currentTime/read",
  "applyPatchApproval",
  "execCommandApproval"
]);

function refusal(method) {
  if (method === "item/commandExecution/requestApproval" || method === "item/fileChange/requestApproval") {
    return { result: { decision: "decline" } };
  }
  if (method === "mcpServer/elicitation/request") return { result: { action: "decline" } };
  return { error: { code: -32601, message: "This proof client does not support the requested operation." } };
}

export function mcpToolApprovalPolicy({ serverName, calls, getTurnId }) {
  return (message) => {
    const params = message.params;
    const meta = params?._meta;
    const toolName = meta?.tool_name;
    const expectedArguments = calls[toolName];
    const properties = params?.requestedSchema?.properties;
    if (
      message.method !== "mcpServer/elicitation/request"
      || params?.serverName !== serverName
      || params?.turnId !== getTurnId()
      || params?.mode !== "form"
      || meta?.codex_approval_kind !== "mcp_tool_call"
      || !Object.hasOwn(calls, toolName)
      || !isDeepStrictEqual(meta?.tool_params ?? {}, expectedArguments)
      || !properties
      || Object.keys(properties).length !== 0
    ) return null;
    return { result: { action: "accept", content: {} } };
  };
}

export class AppServer {
  #child;
  #exit;
  #nextID = 0;
  #pending = new Map();
  #inbound = new Map();
  #notifications = [];
  #waiters = [];
  #methodCounts = new Map();
  #requestOutcomes = new Map();
  #maxNotifications;
  #serverRequestPolicy;
  stderr = "";

  constructor(command, args, { maxNotifications = 256, serverRequestPolicy } = {}) {
    this.#maxNotifications = maxNotifications;
    this.#serverRequestPolicy = serverRequestPolicy;
    this.#child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.#child.stderr.on("data", (chunk) => {
      this.stderr = `${this.stderr}${chunk}`.slice(-8_192);
    });
    readline.createInterface({ input: this.#child.stdout, crlfDelay: Infinity })
      .on("line", (line) => this.#receive(line));
    this.#exit = new Promise((resolve) => {
      this.#child.once("error", (error) => {
        this.#rejectAll(error);
        resolve({ error: error.code ?? "spawn_error" });
      });
      this.#child.once("exit", (code, signal) => {
        this.#rejectAll(new Error(`Codex app-server exited before the request completed (${code ?? signal}).`));
        resolve({ code, signal });
      });
    });
  }

  #count(method) {
    let key = REQUEST_METHODS.has(method) || method.startsWith("turn/") || method.startsWith("thread/")
      ? method
      : "other";
    if (!this.#methodCounts.has(key) && this.#methodCounts.size >= 32) key = "other";
    this.#methodCounts.set(key, (this.#methodCounts.get(key) ?? 0) + 1);
  }

  #send(message) {
    if (!this.#child.stdin.destroyed) this.#child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #receive(line) {
    let message;
    try { message = JSON.parse(line); }
    catch (error) {
      this.#rejectAll(new Error(`Codex app-server emitted invalid JSON: ${error.message}`));
      return;
    }

    if (typeof message.method === "string") {
      this.#count(message.method);
      if (Object.hasOwn(message, "id")) {
        this.#answerServerRequest(message);
        return;
      }
      this.#notifications.push(message);
      if (this.#notifications.length > this.#maxNotifications) this.#notifications.shift();
      for (const waiter of [...this.#waiters]) {
        if (waiter.predicate(message)) {
          this.#waiters.splice(this.#waiters.indexOf(waiter), 1);
          clearTimeout(waiter.timer);
          waiter.resolve(message);
        }
      }
      return;
    }

    if (Object.hasOwn(message, "id")) {
      const pending = this.#pending.get(message.id);
      if (!pending) {
        this.#requestOutcomes.set("orphan_response", (this.#requestOutcomes.get("orphan_response") ?? 0) + 1);
        return;
      }
      this.#pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        const error = new Error(message.error.message ?? "App-server request failed.");
        error.rpcError = message.error;
        pending.reject(error);
      } else pending.resolve(message.result);
    }
  }

  #answerServerRequest(message) {
    this.#inbound.set(message.id, message.method);
    let response;
    let outcome;
    try {
      response = this.#serverRequestPolicy?.(message) ?? refusal(message.method);
      outcome = response.result?.action === "accept" ? "approved" : response.result ? "declined" : "unsupported";
    } catch {
      response = { error: { code: -32603, message: "The proof client could not evaluate the server request." } };
      outcome = "handler_error";
    }
    this.#requestOutcomes.set(outcome, (this.#requestOutcomes.get(outcome) ?? 0) + 1);
    this.#send({ id: message.id, ...response });
    this.#inbound.delete(message.id);
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
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`Timed out waiting for ${method}.`));
      }, timeoutMs);
      this.#pending.set(id, { resolve, reject, timer });
      this.#send({ method, id, params });
    });
  }

  notify(method, params = {}) {
    this.#send({ method, params });
  }

  waitFor(predicate, timeoutMs = 60_000) {
    const prior = this.#notifications.find(predicate);
    if (prior) return Promise.resolve(prior);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, reject };
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

  diagnostics() {
    return {
      receivedMethodCounts: Object.fromEntries([...this.#methodCounts].sort()),
      pendingRequestKinds: [...new Set(this.#inbound.values())].sort(),
      requestOutcomes: Object.fromEntries([...this.#requestOutcomes].sort())
    };
  }

  async close() {
    if (this.#child.exitCode !== null || this.#child.signalCode !== null) return this.#exit;
    this.#child.kill("SIGTERM");
    const grace = await Promise.race([
      this.#exit.then((result) => ({ exited: true, result })),
      new Promise((resolve) => setTimeout(() => resolve({ exited: false }), 2_000))
    ]);
    if (grace.exited) return grace.result;
    this.#child.kill("SIGKILL");
    return this.#exit;
  }
}
