import assert from "node:assert/strict";
import test from "node:test";
import { ProposalStore, ProtocolError } from "../src/protocol.mjs";

const proposal = Object.freeze({
  expectedRevision: 1,
  sceneID: "scene-2",
  replacementText: "Show the decision that changes the result.",
  commandID: "proposal-test-0001"
});

test("a proposal remains pending until explicit acceptance", () => {
  const store = new ProposalStore();
  const before = store.getSnapshot();
  assert.deepEqual(store.submit(proposal), { proposal, revision: 1, state: "pending" });
  assert.deepEqual(store.getSnapshot(), before);
  assert.deepEqual(store.accept(proposal.commandID), { commandID: proposal.commandID, revision: 2, state: "accepted" });
  assert.equal(store.getSnapshot().scenes[1].sentence, proposal.replacementText);
});

test("acceptance is idempotent for a command ID", () => {
  const store = new ProposalStore();
  store.submit(proposal);
  const once = store.accept(proposal.commandID);
  assert.deepEqual(store.accept(proposal.commandID), once);
  assert.equal(store.getSnapshot().revision, 2);
});

test("a command ID cannot identify two proposals", () => {
  const store = new ProposalStore();
  store.submit(proposal);
  assert.throws(() => store.submit({ ...proposal, replacementText: "A different sentence." }), (error) => error instanceof ProtocolError && error.code === "command_conflict");
});

test("stale proposals and malformed inputs are rejected", () => {
  const store = new ProposalStore();
  store.submit(proposal);
  store.accept(proposal.commandID);
  assert.throws(() => store.accept("proposal-other-0002"), (error) => error instanceof ProtocolError && error.code === "unknown_proposal");
  assert.throws(() => store.submit({ ...proposal, expectedRevision: 2, commandID: "proposal-other-0002", extra: true }), (error) => error instanceof ProtocolError && error.code === "invalid_proposal");
  store.submit({ ...proposal, commandID: "proposal-other-0002" });
  assert.throws(() => store.accept("proposal-other-0002"), (error) => error instanceof ProtocolError && error.code === "stale_proposal");
});
