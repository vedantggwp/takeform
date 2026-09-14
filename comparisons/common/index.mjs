import { createHash } from 'node:crypto';
import { lstat, realpath, stat, readFile } from 'node:fs/promises';
import { createReadStream as stream } from 'node:fs';
import path from 'node:path';
import { ComparisonError, TREATMENT_VERSION, asRate, add, compare, comparisonTreatment, freezeTreatment, freezeValue, hydrateFrameState } from './frame-state.mjs';
export { ComparisonError, TREATMENT_VERSION, comparisonTreatment, frameState, hydrateFrameState } from './frame-state.mjs';

const GIB = 1024 ** 3;
const stable = value => Array.isArray(value) ? value.map(stable) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])])) : value;
export const digest = value => createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');
export const treatmentHash = () => digest(comparisonTreatment);

function requireInside(root, candidate) {
  const relative = path.relative(root, candidate);
  if (relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) return candidate;
  throw new ComparisonError(`path escapes fixture root: ${candidate}`, 'path-escape');
}

async function resolvedFile(root, relativePath) {
  if (typeof relativePath !== 'string' || path.isAbsolute(relativePath)) throw new ComparisonError('fixture path must be a relative path', 'path-escape');
  const rootReal = await realpath(root);
  const lexical = requireInside(rootReal, path.resolve(rootReal, relativePath));
  let details;
  try { details = await lstat(lexical); } catch { throw new ComparisonError(`source is missing: ${relativePath}`, 'missing-source'); }
  if (details.isSymbolicLink()) throw new ComparisonError(`source may not be a symlink: ${relativePath}`, 'symlink-escape');
  const physical = await realpath(lexical);
  requireInside(rootReal, physical);
  if (!(await stat(physical)).isFile()) throw new ComparisonError(`source is not a file: ${relativePath}`, 'not-file');
  return physical;
}

async function fileHash(file) {
  const hash = createHash('sha256');
  for await (const chunk of stream(file)) hash.update(chunk);
  return hash.digest('hex');
}

async function jsonFile(root, relativePath) {
  const file = await resolvedFile(root, relativePath);
  try { return JSON.parse(await readFile(file, 'utf8')); } catch { throw new ComparisonError(`invalid JSON: ${relativePath}`, 'invalid-json'); }
}

function selectedSources(manifest) {
  return new Set((manifest.canonicalPlan?.occurrences ?? []).map(occurrence => occurrence.sourceId));
}

function validateManifestShape(manifest) {
  const rate = asRate(manifest.canonicalPlan?.outputFrameRate);
  if (!Number.isInteger(manifest.expected?.frameCount) || manifest.expected.frameCount < 1) throw new ComparisonError(`${manifest.id} has an invalid frame count`, 'invalid-manifest');
  for (const occurrence of manifest.canonicalPlan.occurrences ?? []) {
    if (!occurrence.id || !occurrence.sourceId || !occurrence.outputRange || !occurrence.sourceRange) throw new ComparisonError(`${manifest.id} has an incomplete occurrence`, 'invalid-manifest');
  }
  return rate;
}

function validateOccurrences(manifest) {
  const sources = new Map(manifest.sources.map(source => [source.id, source]));
  for (const occurrence of manifest.canonicalPlan.occurrences ?? []) {
    const source = sources.get(occurrence.sourceId);
    if (!source) throw new ComparisonError(`${manifest.id}/${occurrence.id} refers to an unknown source`, 'unknown-source');
    if (compare(occurrence.sourceRange.start, { ticks: 0, timescale: 1 }) < 0 || compare(occurrence.sourceRange.duration, { ticks: 0, timescale: 1 }) < 0) throw new ComparisonError(`${manifest.id}/${occurrence.id} has a negative source range`, 'invalid-source-range');
    if (source.duration && compare(add(occurrence.sourceRange.start, occurrence.sourceRange.duration), source.duration) > 0) throw new ComparisonError(`${manifest.id}/${occurrence.id} exceeds ${source.id}'s source handle`, 'source-handle-overflow');
  }
}

function validateTreatment(treatment, manifests) {
  if (!treatment || treatment.version !== TREATMENT_VERSION || !treatment.M?.panels || !treatment.T?.caption || !treatment.L) throw new ComparisonError('comparison treatment is incomplete or has the wrong version', 'invalid-treatment');
  const occurrences = manifests.M?.manifest.canonicalPlan.occurrences.filter(item => item.role === 'picture').map(item => item.id) ?? [];
  const panels = Object.keys(treatment.M.panels).sort();
  if (JSON.stringify(panels) !== JSON.stringify([...occurrences].sort())) throw new ComparisonError('M treatment must define exactly one panel for every picture occurrence', 'invalid-treatment');
  const rectangles = new Set();
  for (const id of panels) {
    const panel = treatment.M.panels[id];
    if (!Array.isArray(panel) || panel.length !== 5 || !panel.every(Number.isFinite) || panel[2] <= 0 || panel[3] <= 0) throw new ComparisonError(`M treatment panel ${id} is invalid`, 'invalid-treatment');
    const identity = JSON.stringify(panel); if (rectangles.has(identity)) throw new ComparisonError(`M treatment panel ${id} duplicates another panel`, 'invalid-treatment');
    rectangles.add(identity);
  }
}

export async function freezeSnapshot({ fixtureRoot, acceptedCommit, treatment = comparisonTreatment }) {
  if (!/^[0-9a-f]{40}$/.test(acceptedCommit ?? '')) throw new ComparisonError('acceptedCommit must be a full git SHA', 'invalid-commit');
  const frozenTreatment = freezeTreatment(treatment);
  const registry = await jsonFile(fixtureRoot, 'registry.json');
  const manifests = {};
  const sourceReports = [];
  for (const entry of registry.fixtures ?? []) {
    const manifest = await jsonFile(fixtureRoot, entry.path);
    const rate = validateManifestShape(manifest); validateOccurrences(manifest);
    const selected = selectedSources(manifest);
    manifests[manifest.id] = { manifest, manifestHash: digest(manifest), rate };
    for (const source of manifest.sources) {
      const isSelected = selected.has(source.id);
      const declaredCorrupt = source.kind === 'corrupt';
      if (declaredCorrupt && !isSelected) {
        sourceReports.push({ fixtureId: manifest.id, sourceId: source.id, status: 'declared-unused-corrupt', path: source.path });
        continue;
      }
      if (declaredCorrupt) throw new ComparisonError(`selected source is declared corrupt: ${manifest.id}/${source.id}`, 'selected-corrupt-source');
      const file = await resolvedFile(fixtureRoot, path.join(manifest.id, source.path));
      const actualHash = await fileHash(file);
      if (actualHash !== source.sha256) throw new ComparisonError(`hash mismatch for ${manifest.id}/${source.id}`, 'hash-mismatch');
      const bytes = (await stat(file)).size;
      sourceReports.push({ fixtureId: manifest.id, sourceId: source.id, status: isSelected ? 'selected' : 'verified-unused', path: path.join(manifest.id, source.path), bytes, sha256: actualHash });
    }
  }
  validateTreatment(frozenTreatment, manifests);
  const snapshot = { version: 1, acceptedCommit, treatmentVersion: frozenTreatment.version, treatmentHash: digest(frozenTreatment), manifests: Object.fromEntries(Object.entries(manifests).map(([id, item]) => [id, { manifestHash: item.manifestHash, frameCount: item.manifest.expected.frameCount, rate: item.rate }])), sources: sourceReports };
  const snapshotId = digest(snapshot);
  return freezeValue({ ...snapshot, ...hydrateFrameState({ snapshotId, manifests, treatment: frozenTreatment }) });
}

export function assertSnapshotIdentity(snapshot, expectedSnapshotId) {
  if (!snapshot || snapshot.snapshotId !== expectedSnapshotId) throw new ComparisonError('snapshot identity does not match the attempt', 'wrong-snapshot-identity');
  return snapshot;
}

export function reserveStorage({ route, width, height, frameCount, scale = 1, expectedOutputBytes = 0, decodeCacheBytes = 0, pipelineBufferBytes = 0, freeBytes, runtimeFreeFloorBytes = GIB }) {
  if (!Number.isInteger(width) || !Number.isInteger(height) || !Number.isInteger(frameCount) || width < 1 || height < 1 || frameCount < 1 || !Number.isFinite(scale) || scale <= 0) throw new ComparisonError('storage dimensions, frame count, and scale must be positive', 'invalid-reservation');
  const frameBytes = frameCount * Math.ceil(width * scale) * Math.ceil(height * scale) * 4;
  const requiredBytes = route === 'disk' ? frameBytes + expectedOutputBytes + GIB : decodeCacheBytes + pipelineBufferBytes + expectedOutputBytes + runtimeFreeFloorBytes;
  if (!Number.isFinite(freeBytes) || freeBytes < requiredBytes) throw new ComparisonError(`insufficient reserve: need ${requiredBytes}, have ${freeBytes}`, 'insufficient-reserve');
  return { route, frameBytes: route === 'disk' ? frameBytes : null, expectedOutputBytes, decodeCacheBytes: route === 'streaming' ? decodeCacheBytes : null, pipelineBufferBytes: route === 'streaming' ? pipelineBufferBytes : null, reserveBytes: GIB, runtimeFreeFloorBytes: route === 'streaming' ? runtimeFreeFloorBytes : null, requiredBytes, freeBytes };
}

export function createAttempt({ id, snapshotId, backend, declaredPaths }) {
  if (!id || !snapshotId || !backend || !Array.isArray(declaredPaths) || declaredPaths.length === 0) throw new ComparisonError('attempt needs id, snapshot, backend, and declared paths', 'invalid-attempt');
  return { version: 1, id, snapshotId, backend, declaredPaths, status: 'running', startedAt: new Date().toISOString(), terminalInventory: null, outputReceipt: null };
}
export function finishAttempt(attempt, { status, terminalInventory, outputReceipt = null }) {
  if (attempt.status !== 'running' || !['completed', 'failed', 'interrupted'].includes(status) || !Array.isArray(terminalInventory)) throw new ComparisonError('invalid attempt terminal transition', 'invalid-attempt-transition');
  if (status === 'completed' && (!outputReceipt || outputReceipt.status !== 'completed')) throw new ComparisonError('completed attempt requires a completed output receipt', 'missing-output-receipt');
  if (status !== 'completed' && outputReceipt?.status === 'completed') throw new ComparisonError('a non-completed attempt may not own a completed output receipt', 'invalid-output-receipt');
  return { ...attempt, status, terminalInventory, outputReceipt, endedAt: new Date().toISOString() };
}

export function measurementSummary(fixtureId, backend = { identity: 'fake', version: 'no-renderer' }) {
  return { schemaVersion: 1, fixtureId, machine: { model: 'unspecified', arch: process.arch, chip: 'unspecified' }, osBuild: 'unspecified', toolPins: { node: process.version }, backend, renderSettings: { verdict: 'fake backend; no renderer or performance verdict' }, runKind: 'cold', wallTimeSeconds: null, peakRssBytes: null, seekLatenciesMs: [], firstPreviewFrameSeconds: null, outputSha256: null, probeSummary: null, checks: [{ id: 'renderer', status: 'not_run', detail: 'Fake lifecycle validation only.' }], failures: [], rawRuns: [] };
}
