const commandIDPattern = /^proposal-[a-z0-9-]{8,64}$/;

export const initialProject = Object.freeze({
  revision: 1,
  scenes: [
    { id: "scene-1", sentence: "Open with the creator's tension." },
    { id: "scene-2", sentence: "Show the one decision that changes the result." },
    { id: "scene-3", sentence: "End with a repeatable takeaway." }
  ]
});

export class ProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export function snapshot(project) {
  return structuredClone(project);
}

export function parseProposal(raw, project) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new ProtocolError("invalid_proposal", "Proposal must be an object.");
  }
  const keys = ["expectedRevision", "sceneID", "replacementText", "commandID"];
  if (Object.keys(raw).length !== keys.length || !keys.every((key) => key in raw)) {
    throw new ProtocolError("invalid_proposal", "Proposal must contain exactly the required fields.");
  }
  if (!Number.isInteger(raw.expectedRevision) || raw.expectedRevision < 1) {
    throw new ProtocolError("invalid_proposal", "expectedRevision must be a positive integer.");
  }
  if (typeof raw.sceneID !== "string" || !project.scenes.some((scene) => scene.id === raw.sceneID)) {
    throw new ProtocolError("invalid_proposal", "sceneID must identify an existing scene.");
  }
  if (typeof raw.replacementText !== "string" || raw.replacementText.trim().length < 1 || raw.replacementText.length > 160) {
    throw new ProtocolError("invalid_proposal", "replacementText must contain 1 to 160 characters.");
  }
  if (typeof raw.commandID !== "string" || !commandIDPattern.test(raw.commandID)) {
    throw new ProtocolError("invalid_proposal", "commandID must be a generated proposal identifier.");
  }
  return Object.freeze({ ...raw });
}

export class ProposalStore {
  #project;
  #proposals = new Map();
  #accepted = new Map();

  constructor(project = initialProject) {
    this.#project = snapshot(project);
  }

  getSnapshot() {
    return snapshot(this.#project);
  }

  getPending() {
    return [...this.#proposals.values()]
      .filter((proposal) => !this.#accepted.has(proposal.commandID))
      .map((proposal) => structuredClone(proposal));
  }

  submit(raw) {
    const proposal = parseProposal(raw, this.#project);
    const known = this.#proposals.get(proposal.commandID);
    if (known && JSON.stringify(known) !== JSON.stringify(proposal)) {
      throw new ProtocolError("command_conflict", "commandID already identifies a different proposal.");
    }
    this.#proposals.set(proposal.commandID, proposal);
    return { proposal, revision: this.#project.revision, state: "pending" };
  }

  accept(commandID) {
    const completed = this.#accepted.get(commandID);
    if (completed) return structuredClone(completed);
    const proposal = this.#proposals.get(commandID);
    if (!proposal) throw new ProtocolError("unknown_proposal", "No pending proposal matches commandID.");
    if (proposal.expectedRevision !== this.#project.revision) {
      throw new ProtocolError("stale_proposal", "Proposal revision does not match the current project revision.");
    }
    this.#project.scenes = this.#project.scenes.map((scene) => (
      scene.id === proposal.sceneID ? { ...scene, sentence: proposal.replacementText } : scene
    ));
    this.#project.revision += 1;
    const result = { commandID, revision: this.#project.revision, state: "accepted" };
    this.#accepted.set(commandID, result);
    return structuredClone(result);
  }
}
