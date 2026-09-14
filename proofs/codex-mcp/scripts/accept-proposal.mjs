import { readFileSync, writeFileSync } from "node:fs";
import { ProposalStore } from "../src/protocol.mjs";

const proposal = JSON.parse(readFileSync(process.argv[2], "utf8"));
const store = new ProposalStore();
const before = store.getSnapshot();
const pending = store.submit(proposal);
const accepted = store.accept(proposal.commandID);
const stale = { ...proposal, commandID: "proposal-stale-20260914" };
store.submit(stale);
let staleRejection;
try {
  store.accept(stale.commandID);
} catch (error) {
  staleRejection = error.code;
}
writeFileSync(process.argv[3], `${JSON.stringify({ before, pending, accepted, after: store.getSnapshot(), staleRejection })}\n`);
