import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { createReadStream as stream } from 'node:fs';
import { lstat, readFile, realpath, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { ComparisonError, TREATMENT_VERSION, add, asRate, asRational, compare, comparisonTreatment, freezeTreatment, freezeValue, hydrateFrameState, multiply, subtract } from './frame-state.mjs';

export { ComparisonError, TREATMENT_VERSION, comparisonTreatment, frameState, hydrateFrameState } from './frame-state.mjs';

const GIB = 1024 ** 3;
const EXPECTED_FIXTURES = Object.freeze({ M: { width: 1920, height: 1080, frameCount: 480, rate: { num: 30, den: 1 } }, T: { width: 1920, height: 1080, frameCount: 2700, rate: { num: 30, den: 1 } }, L: { width: 1920, height: 1080, frameCount: 43157, rate: { num: 24000, den: 1001 } } });
const execFileAsync = promisify(execFile);
const acceptedSnapshots = new WeakSet();
const validatorPath = fileURLToPath(new URL('../../fixtures/lib/validate-schema.mjs', import.meta.url));
const schemaPath = fileURLToPath(new URL('../../fixtures/schema/fixture-manifest.schema.json', import.meta.url));
const stable = value => Array.isArray(value) ? value.map(stable) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])])) : value;

export const digest = value => createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');
export const treatmentHash = () => digest(comparisonTreatment);

function requireInside(root, candidate, allowRoot = true) {
  const relative = path.relative(root, candidate);
  if ((allowRoot && relative === '') || (relative !== '' && !relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) return candidate;
  throw new ComparisonError(`path escapes owned root: ${candidate}`, 'path-escape');
}

async function resolvedFile(root, relativePath) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || path.isAbsolute(relativePath)) throw new ComparisonError('fixture path must be a relative path', 'path-escape');
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

async function readJsonFile(file, label) {
  try { return JSON.parse(await readFile(file, 'utf8')); } catch { throw new ComparisonError(`invalid JSON: ${label}`, 'invalid-json'); }
}

async function jsonFile(root, relativePath) {
  const file = await resolvedFile(root, relativePath);
  return readJsonFile(file, relativePath);
}

async function validateManifestSchema(file, fixtureId) {
  try {
    await execFileAsync(process.execPath, [validatorPath, schemaPath, file], { encoding: 'utf8' });
  } catch (error) {
    const detail = `${error.stderr ?? error.stdout ?? error.message}`.trim();
    throw new ComparisonError(`${fixtureId} fails fixture schema: ${detail}`, 'invalid-manifest');
  }
}

function validateRegistry(registry) {
  if (registry?.schemaVersion !== 1 || registry.manifestSchema !== 'schema/fixture-manifest.schema.json' || !Array.isArray(registry.fixtures)) throw new ComparisonError('fixture registry is incomplete', 'invalid-registry');
  const ids = registry.fixtures.map(entry => entry.id);
  if (new Set(ids).size !== ids.length || JSON.stringify([...ids].sort()) !== JSON.stringify(Object.keys(EXPECTED_FIXTURES).sort())) throw new ComparisonError('fixture registry must contain exactly M, T, and L', 'invalid-registry');
  for (const entry of registry.fixtures) if (entry.path !== `${entry.id}/manifest.json`) throw new ComparisonError(`fixture ${entry.id} has an unexpected manifest path`, 'invalid-registry');
}

function selectedSources(manifest) {
  return new Set(manifest.canonicalPlan.occurrences.map(occurrence => occurrence.sourceId));
}

function rangeEnd(range) {
  return add(range.start, range.duration);
}

function frameCountForDuration(duration, rate) {
  const value = asRational(duration, 'output duration');
  const numerator = BigInt(value.ticks) * BigInt(rate.num);
  const denominator = BigInt(value.timescale) * BigInt(rate.den);
  const frames = (numerator + denominator - 1n) / denominator;
  const number = Number(frames);
  if (!Number.isSafeInteger(number) || BigInt(number) !== frames) throw new ComparisonError('frame count exceeds safe integer range', 'unsafe-rational');
  return number;
}

function validateOccurrences(manifest) {
  const sources = new Map();
  for (const source of manifest.sources) {
    if (sources.has(source.id)) throw new ComparisonError(`${manifest.id} has duplicate source ${source.id}`, 'invalid-manifest');
    sources.set(source.id, source);
    if (source.duration && asRational(source.duration, `${source.id} duration`).ticks < 0) throw new ComparisonError(`${source.id} has a negative duration`, 'invalid-range');
  }
  const occurrenceIds = new Set();
  for (const occurrence of manifest.canonicalPlan.occurrences) {
    if (occurrenceIds.has(occurrence.id)) throw new ComparisonError(`${manifest.id} has duplicate occurrence ${occurrence.id}`, 'invalid-manifest');
    occurrenceIds.add(occurrence.id);
    const source = sources.get(occurrence.sourceId);
    if (!source) throw new ComparisonError(`${manifest.id}/${occurrence.id} refers to an unknown source`, 'unknown-source');
    const sourceStart = asRational(occurrence.sourceRange.start, `${occurrence.id} source start`);
    const sourceDuration = asRational(occurrence.sourceRange.duration, `${occurrence.id} source duration`);
    const outputStart = asRational(occurrence.outputRange.start, `${occurrence.id} output start`);
    const outputDuration = asRational(occurrence.outputRange.duration, `${occurrence.id} output duration`);
    const retime = asRate(occurrence.retimeFactor);
    if (sourceStart.ticks < 0 || sourceDuration.ticks < 0 || outputStart.ticks < 0 || outputDuration.ticks < 1) throw new ComparisonError(`${manifest.id}/${occurrence.id} has an invalid range`, 'invalid-range');
    if (compare(rangeEnd(occurrence.outputRange), manifest.expected.outputDuration) > 0n) throw new ComparisonError(`${manifest.id}/${occurrence.id} exceeds the output duration`, 'output-range-overflow');
    if (source.duration && compare(rangeEnd(occurrence.sourceRange), source.duration) > 0n) throw new ComparisonError(`${manifest.id}/${occurrence.id} exceeds ${source.id}'s source handle`, 'source-handle-overflow');
    if (sourceDuration.ticks > 0 && compare(multiply(outputDuration, retime), sourceDuration) !== 0n) throw new ComparisonError(`${manifest.id}/${occurrence.id} has inconsistent retime mapping`, 'invalid-retime');
  }
}

function validateManifestMeaning(manifest, expectedId) {
  const expected = EXPECTED_FIXTURES[expectedId];
  if (manifest.id !== expectedId || manifest.canonicalPlan.width !== expected.width || manifest.canonicalPlan.height !== expected.height || manifest.expected.frameCount !== expected.frameCount) throw new ComparisonError(`${expectedId} does not match the accepted dimensions or frame count`, 'invalid-manifest');
  const rate = asRate(manifest.canonicalPlan.outputFrameRate);
  if (rate.num !== expected.rate.num || rate.den !== expected.rate.den) throw new ComparisonError(`${expectedId} does not match the accepted frame rate`, 'invalid-manifest');
  if (asRational(manifest.expected.outputDuration, `${expectedId} output duration`).ticks < 0 || frameCountForDuration(manifest.expected.outputDuration, rate) !== expected.frameCount) throw new ComparisonError(`${expectedId} frame count does not match its duration`, 'invalid-manifest');
  validateOccurrences(manifest);
  if (expectedId === 'T') validateTalkManifest(manifest);
  return rate;
}

function sameRational(left, right) { return compare(left, right) === 0n; }

function validateTalkManifest(manifest) {
  const dialogue = new Map(manifest.canonicalPlan.occurrences.filter(item => item.role === 'dialogue').map(item => [item.id, item]));
  const cuts = manifest.canonicalPlan.cutList ?? [];
  if (dialogue.size === 0 || cuts.length !== dialogue.size) throw new ComparisonError('T cut list must match every dialogue occurrence', 'invalid-manifest');
  const cutIds = new Set();
  for (const cut of cuts) {
    const occurrence = dialogue.get(cut.occurrenceId);
    const cutRetime = cut.retimeFactor ?? { num: 1, den: 1 };
    if (cutIds.has(cut.occurrenceId) || !occurrence || cut.takeSourceId !== occurrence.sourceId || !sameRational(cut.sourceRange.start, occurrence.sourceRange.start) || !sameRational(cut.sourceRange.duration, occurrence.sourceRange.duration) || !sameRational(cut.outputRange.start, occurrence.outputRange.start) || !sameRational(cut.outputRange.duration, occurrence.outputRange.duration) || asRate(cutRetime).num !== asRate(occurrence.retimeFactor).num || asRate(cutRetime).den !== asRate(occurrence.retimeFactor).den) throw new ComparisonError(`T cut ${cut.occurrenceId} does not match its dialogue occurrence`, 'invalid-manifest');
    cutIds.add(cut.occurrenceId);
  }
  for (const caption of manifest.expected.captions ?? []) {
    const occurrence = dialogue.get(caption.occurrenceId);
    if (!occurrence || caption.takeSourceId !== occurrence.sourceId || caption.straddlesCut !== false || compare(caption.outputRange.start, occurrence.outputRange.start) < 0n || compare(rangeEnd(caption.outputRange), rangeEnd(occurrence.outputRange)) > 0n) throw new ComparisonError(`T caption ${caption.text} is not bound to one dialogue occurrence`, 'invalid-manifest');
  }
  const chapters = manifest.canonicalPlan.authorChapters ?? [];
  if (chapters.length === 0 || compare(chapters[0].outputStart, { ticks: 0, timescale: 1 }) !== 0n) throw new ComparisonError('T author chapters must start at zero', 'invalid-manifest');
  for (let index = 1; index < chapters.length; index += 1) if (compare(chapters[index - 1].outputStart, chapters[index].outputStart) >= 0n) throw new ComparisonError('T author chapters must be strictly ordered', 'invalid-manifest');
  if (manifest.canonicalPlan.occurrences.filter(item => item.role === 'music').length !== 1) throw new ComparisonError('T must contain one canonical music occurrence', 'invalid-manifest');
}

function validateTreatment(treatment, manifests) {
  if (!treatment || treatment.version !== TREATMENT_VERSION) throw new ComparisonError('comparison treatment has the wrong version', 'invalid-treatment');
  const m = treatment.M;
  if (!m || m.fit !== 'cover' || m.entrance?.curve !== 'linear' || !Number.isSafeInteger(m.entrance.frames) || m.entrance.frames < 1 || !Number.isFinite(m.drift?.amplitude) || m.drift.amplitude < 0 || !Number.isSafeInteger(m.drift.periodFrames) || m.drift.periodFrames < 1 || !/^#[0-9a-f]{6}$/i.test(m.border?.color ?? '') || !Number.isFinite(m.border?.width) || m.border.width <= 0 || m.border.width >= 0.1) throw new ComparisonError('M treatment is invalid', 'invalid-treatment');
  const occurrences = manifests.M.manifest.canonicalPlan.occurrences.filter(item => item.role === 'picture').map(item => item.id);
  const panels = Object.keys(m.panels ?? {}).sort();
  if (JSON.stringify(panels) !== JSON.stringify([...occurrences].sort())) throw new ComparisonError('M treatment must define exactly one panel for every picture occurrence', 'invalid-treatment');
  const rectangles = new Set();
  for (const id of panels) {
    const panel = m.panels[id];
    if (!Array.isArray(panel) || panel.length !== 5 || !panel.every(Number.isFinite) || panel[0] < 0 || panel[1] < 0 || panel[2] <= 0 || panel[3] <= 0 || panel[0] + panel[2] > 1 || panel[1] + panel[3] > 1) throw new ComparisonError(`M treatment panel ${id} is invalid`, 'invalid-treatment');
    const identity = JSON.stringify(panel);
    if (rectangles.has(identity)) throw new ComparisonError(`M treatment panel ${id} duplicates another panel`, 'invalid-treatment');
    rectangles.add(identity);
  }
  const t = treatment.T;
  const caption = t?.caption;
  const audio = t?.audio;
  const finiteAudio = ['musicDbDuringDialogue', 'musicDbInGaps', 'attackMs', 'releaseMs', 'sfxDb', 'targetIntegratedLufs', 'maxTruePeakDbtp'].every(key => Number.isFinite(audio?.[key]));
  if (t?.pictureAudio !== 'muted' || !caption || typeof caption.fontFamily !== 'string' || !caption.fontFamily || !Number.isFinite(caption.fontSizePx) || caption.fontSizePx <= 0 || caption.lineWrap !== 'greedy-two-lines' || caption.maxLines !== 2 || !/^#[0-9a-f]{6}$/i.test(caption.color ?? '') || !/^#[0-9a-f]{6}$/i.test(caption.backplate ?? '') || !Number.isFinite(caption.safeMargin) || caption.safeMargin <= 0 || caption.safeMargin >= 0.5 || !finiteAudio || !Number.isSafeInteger(audio.attackMs) || audio.attackMs <= 0 || !Number.isSafeInteger(audio.releaseMs) || audio.releaseMs <= 0 || audio.musicDbDuringDialogue >= audio.musicDbInGaps || audio.maxTruePeakDbtp > 0 || audio.gainInterpolation !== 'linear-db') throw new ComparisonError('T treatment is invalid', 'invalid-treatment');
  const l = treatment.L;
  const transitions = manifests.L.manifest.canonicalPlan.occurrences.filter(item => item.role === 'transition');
  if (!l || l.transitionFrames !== 24 || l.pictureOpacity !== 'linear' || l.audioCurve !== 'equal-power' || l.chapterLabel !== 'source-id' || transitions.length !== 14) throw new ComparisonError('L treatment is invalid', 'invalid-treatment');
  for (const transition of transitions) if (frameCountForDuration(transition.outputRange.duration, manifests.L.rate) !== l.transitionFrames) throw new ComparisonError(`${transition.id} does not match the treatment duration`, 'invalid-treatment');
}

function decimalRational(value, label) {
  if (!Number.isFinite(value) || value < 0) throw new ComparisonError(`${label} must be a nonnegative finite time`, 'invalid-speech-region');
  const ticks = Math.round(value * 1_000_000);
  if (!Number.isSafeInteger(ticks)) throw new ComparisonError(`${label} exceeds safe timing precision`, 'unsafe-rational');
  return asRational({ ticks, timescale: 1_000_000 }, label);
}

function minRational(left, right) { return compare(left, right) <= 0n ? left : right; }
function maxRational(left, right) { return compare(left, right) >= 0n ? left : right; }

function projectSpeechRanges(manifest, wordFiles) {
  const ranges = [];
  for (const occurrence of manifest.canonicalPlan.occurrences.filter(item => item.role === 'dialogue')) {
    const words = wordFiles.get(occurrence.sourceId)?.words;
    if (!Array.isArray(words) || words.length === 0) throw new ComparisonError(`missing measured words for ${occurrence.sourceId}`, 'invalid-speech-region');
    const sourceEnd = rangeEnd(occurrence.sourceRange);
    for (const word of words) {
      const wordStart = decimalRational(word.sourceStartSeconds, `${word.id} start`);
      const wordEnd = decimalRational(word.acousticTailEndSeconds ?? word.sourceEndSeconds, `${word.id} end`);
      if (compare(wordEnd, wordStart) <= 0n || compare(wordEnd, occurrence.sourceRange.start) <= 0n || compare(wordStart, sourceEnd) >= 0n) continue;
      const clippedStart = maxRational(wordStart, occurrence.sourceRange.start);
      const clippedEnd = minRational(wordEnd, sourceEnd);
      const inverseRetime = { num: occurrence.retimeFactor.den, den: occurrence.retimeFactor.num };
      const outputStart = add(occurrence.outputRange.start, multiply(subtract(clippedStart, occurrence.sourceRange.start), inverseRetime));
      const outputEnd = add(occurrence.outputRange.start, multiply(subtract(clippedEnd, occurrence.sourceRange.start), inverseRetime));
      ranges.push({ start: outputStart, duration: subtract(outputEnd, outputStart), occurrenceId: occurrence.id, sourceId: occurrence.sourceId, wordId: word.id });
    }
  }
  return ranges.sort((left, right) => compare(left.start, right.start) < 0n ? -1 : compare(left.start, right.start) > 0n ? 1 : 0);
}

async function loadSpeechData(fixtureRoot, manifest) {
  const wordFiles = new Map();
  const supportingFiles = [];
  const sourceIds = [...new Set(manifest.canonicalPlan.occurrences.filter(item => item.role === 'dialogue').map(item => item.sourceId))];
  for (const sourceId of sourceIds) {
    const relativePath = sourceId === 'take1' ? manifest.expected.wordTimingReceipt.path : `words-${sourceId}.json`;
    const fixturePath = path.join('T', relativePath);
    const file = await resolvedFile(fixtureRoot, fixturePath);
    const data = await readJsonFile(file, fixturePath);
    if (data.isHumanGroundTruth !== false || !Array.isArray(data.words) || data.words.length === 0 || data.words.some(word => typeof word.id !== 'string' || !word.id.startsWith(`${sourceId}-word-`))) throw new ComparisonError(`${fixturePath} has invalid word timing provenance`, 'invalid-speech-region');
    let previousStart = -1;
    for (const word of data.words) {
      const start = decimalRational(word.sourceStartSeconds, `${word.id} start`);
      const end = decimalRational(word.acousticTailEndSeconds ?? word.sourceEndSeconds, `${word.id} end`);
      if (compare(end, start) <= 0n || compare(start, { ticks: previousStart, timescale: 1_000_000 }) < 0n) throw new ComparisonError(`${word.id} has invalid measured timing`, 'invalid-speech-region');
      previousStart = Math.round(word.sourceStartSeconds * 1_000_000);
    }
    wordFiles.set(sourceId, data);
    supportingFiles.push({ fixtureId: 'T', role: 'measured-word-regions', sourceId, path: fixturePath, bytes: (await stat(file)).size, sha256: await fileHash(file) });
  }
  const dialogue = new Map(manifest.canonicalPlan.occurrences.filter(item => item.role === 'dialogue').map(item => [item.id, item]));
  for (const correction of manifest.canonicalPlan.wordCorrections ?? []) {
    const word = wordFiles.get(correction.sourceId)?.words.find(item => item.id === correction.wordId);
    if (!word || word.text !== correction.fromText || correction.timingUnchanged !== true || correction.occurrenceIds.some(id => dialogue.get(id)?.sourceId !== correction.sourceId)) throw new ComparisonError(`word correction ${correction.wordId} lacks its measured source identity`, 'invalid-speech-region');
  }
  return { speechRanges: projectSpeechRanges(manifest, wordFiles), supportingFiles };
}

function validateLongTransitions(manifest) {
  const occurrences = manifest.canonicalPlan.occurrences;
  const boundaries = manifest.expected.chapterBoundaries;
  const transitions = occurrences.filter(item => item.role === 'transition');
  const chapters = occurrences.filter(item => item.role === 'picture' && item.id.startsWith('ochapter'));
  if (chapters.length !== 15 || transitions.length !== 14 || boundaries.length !== 16) throw new ComparisonError('L must contain fifteen chapters and fourteen joins', 'invalid-transition');
  for (const transition of transitions) {
    const index = occurrences.indexOf(transition);
    const outgoing = occurrences[index - 1];
    const incoming = occurrences[index + 1];
    if (!outgoing || !outgoing.id.startsWith('ochapter') || transition.sourceId !== outgoing.sourceId || !incoming || !incoming.id.startsWith('ochapter')) throw new ComparisonError(`${transition.id} lacks its canonical chapter pair`, 'invalid-transition');
    const midpoint = add(transition.outputRange.start, multiply(transition.outputRange.duration, { num: 1, den: 2 }));
    const boundary = boundaries.find(item => compare(item.outputTime, midpoint) === 0n && !item.clean);
    const incomingStart = subtract(incoming.sourceRange.start, multiply(transition.outputRange.duration, { num: 1, den: 2 }));
    const incomingSource = manifest.sources.find(source => source.id === incoming.sourceId);
    if (!boundary || incomingStart.ticks < 0 || compare(add(incomingStart, transition.outputRange.duration), incomingSource.duration) > 0n) throw new ComparisonError(`${transition.id} lacks bounded named handles`, 'invalid-transition');
  }
}

export async function freezeSnapshot({ fixtureRoot, acceptedCommit, treatment = comparisonTreatment }) {
  if (!/^[0-9a-f]{40}$/.test(acceptedCommit ?? '')) throw new ComparisonError('acceptedCommit must be a full git SHA', 'invalid-commit');
  const frozenTreatment = freezeTreatment(treatment);
  const registry = await jsonFile(fixtureRoot, 'registry.json');
  validateRegistry(registry);
  const manifests = {};
  const sourceReports = [];
  for (const entry of registry.fixtures) {
    const manifestFile = await resolvedFile(fixtureRoot, entry.path);
    await validateManifestSchema(manifestFile, entry.id);
    const manifest = await readJsonFile(manifestFile, entry.path);
    const rate = validateManifestMeaning(manifest, entry.id);
    const selected = selectedSources(manifest);
    manifests[manifest.id] = { manifest, manifestHash: digest(manifest), rate };
    for (const source of manifest.sources) {
      const isSelected = selected.has(source.id);
      const declaredCorrupt = source.kind === 'corrupt';
      if (declaredCorrupt && isSelected) throw new ComparisonError(`selected source is declared corrupt: ${manifest.id}/${source.id}`, 'selected-corrupt-source');
      const relativePath = path.join(manifest.id, source.path);
      const file = await resolvedFile(fixtureRoot, relativePath);
      const actualHash = await fileHash(file);
      if (actualHash !== source.sha256) throw new ComparisonError(`hash mismatch for ${manifest.id}/${source.id}`, 'hash-mismatch');
      sourceReports.push({ fixtureId: manifest.id, sourceId: source.id, status: declaredCorrupt ? 'declared-unused-corrupt' : isSelected ? 'selected' : 'verified-unused', path: relativePath, bytes: (await stat(file)).size, sha256: actualHash });
    }
  }
  validateLongTransitions(manifests.L.manifest);
  const speech = await loadSpeechData(fixtureRoot, manifests.T.manifest);
  manifests.T.speechRanges = speech.speechRanges;
  validateTreatment(frozenTreatment, manifests);
  const snapshot = {
    version: 1,
    acceptedCommit,
    treatmentVersion: frozenTreatment.version,
    treatmentHash: digest(frozenTreatment),
    manifests: Object.fromEntries(Object.entries(manifests).map(([id, item]) => [id, { manifestHash: item.manifestHash, frameCount: item.manifest.expected.frameCount, rate: item.rate, speechRangesHash: item.speechRanges ? digest(item.speechRanges) : null }])),
    sources: sourceReports,
    supportingFiles: speech.supportingFiles,
  };
  const snapshotId = digest(snapshot);
  const accepted = freezeValue({ ...snapshot, ...hydrateFrameState({ snapshotId, manifests, treatment: frozenTreatment }) });
  acceptedSnapshots.add(accepted);
  return accepted;
}

export function assertSnapshotIdentity(snapshot, expectedSnapshotId) {
  if (!snapshot || !/^[a-f0-9]{64}$/.test(expectedSnapshotId ?? '') || snapshot.snapshotId !== expectedSnapshotId) throw new ComparisonError('snapshot identity does not match the attempt', 'wrong-snapshot-identity');
  return snapshot;
}

function nonnegativeSafeInteger(value, name, positive = false) {
  if (!Number.isSafeInteger(value) || value < (positive ? 1 : 0)) throw new ComparisonError(`${name} must be a ${positive ? 'positive' : 'nonnegative'} safe integer`, 'invalid-reservation');
  return value;
}

function safeTotal(parts) {
  const total = parts.reduce((sum, value) => sum + BigInt(value), 0n);
  const number = Number(total);
  if (!Number.isSafeInteger(number) || BigInt(number) !== total) throw new ComparisonError('storage reservation exceeds the safe integer range', 'invalid-reservation');
  return number;
}

function safeProduct(parts) {
  const product = parts.reduce((value, part) => value * BigInt(part), 1n);
  const number = Number(product);
  if (!Number.isSafeInteger(number) || BigInt(number) !== product) throw new ComparisonError('storage reservation exceeds the safe integer range', 'invalid-reservation');
  return number;
}

export function reserveStorage({ route, width, height, frameCount, scale = 1, expectedOutputBytes, decodeCacheBytes, pipelineBufferBytes, freeBytes, runtimeFreeFloorBytes }) {
  if (!['disk', 'streaming'].includes(route)) throw new ComparisonError('storage route must be disk or streaming', 'invalid-reservation');
  nonnegativeSafeInteger(width, 'width', true);
  nonnegativeSafeInteger(height, 'height', true);
  nonnegativeSafeInteger(frameCount, 'frameCount', true);
  if (!Number.isFinite(scale) || scale <= 0) throw new ComparisonError('scale must be positive', 'invalid-reservation');
  const scaledWidth = Math.ceil(width * scale);
  const scaledHeight = Math.ceil(height * scale);
  nonnegativeSafeInteger(scaledWidth, 'scaled width', true);
  nonnegativeSafeInteger(scaledHeight, 'scaled height', true);
  nonnegativeSafeInteger(expectedOutputBytes, 'expectedOutputBytes', true);
  nonnegativeSafeInteger(freeBytes, 'freeBytes');
  const frameBytes = safeProduct([frameCount, scaledWidth, scaledHeight, 4]);
  let requiredBytes;
  if (route === 'disk') requiredBytes = safeTotal([frameBytes, expectedOutputBytes, GIB]);
  else {
    nonnegativeSafeInteger(decodeCacheBytes, 'decodeCacheBytes', true);
    nonnegativeSafeInteger(pipelineBufferBytes, 'pipelineBufferBytes', true);
    nonnegativeSafeInteger(runtimeFreeFloorBytes, 'runtimeFreeFloorBytes', true);
    requiredBytes = safeTotal([decodeCacheBytes, pipelineBufferBytes, expectedOutputBytes, runtimeFreeFloorBytes]);
  }
  if (freeBytes < requiredBytes) throw new ComparisonError(`insufficient reserve: need ${requiredBytes}, have ${freeBytes}`, 'insufficient-reserve');
  return { route, frameBytes: route === 'disk' ? frameBytes : null, expectedOutputBytes, decodeCacheBytes: route === 'streaming' ? decodeCacheBytes : null, pipelineBufferBytes: route === 'streaming' ? pipelineBufferBytes : null, reserveBytes: route === 'disk' ? GIB : null, runtimeFreeFloorBytes: route === 'streaming' ? runtimeFreeFloorBytes : null, requiredBytes, freeBytes };
}

function validateBackend(backend) {
  if (!backend || typeof backend !== 'object' || typeof backend.identity !== 'string' || typeof backend.version !== 'string' || !backend.version) throw new ComparisonError('attempt backend must have identity, version, and kind', 'invalid-attempt');
  if (backend.kind === 'fake' && backend.identity === 'fake') return backend;
  if (backend.kind === 'renderer' && ['remotion', 'hyperframes'].includes(backend.identity)) return backend;
  throw new ComparisonError('attempt backend is not an accepted fake or renderer identity', 'invalid-attempt');
}

export function createAttempt({ id, snapshot, snapshotId, backend, attemptRoot, scratchPaths, outputPath = null }) {
  if (typeof id !== 'string' || !/^[a-zA-Z0-9._-]+$/.test(id) || !path.isAbsolute(attemptRoot ?? '') || path.basename(attemptRoot) !== id || !Array.isArray(scratchPaths) || scratchPaths.length === 0) throw new ComparisonError('attempt needs a safe id, snapshot identity, owned root, and scratch paths', 'invalid-attempt');
  const acceptedBackend = validateBackend(backend);
  const boundSnapshotId = acceptedBackend.kind === 'renderer' ? snapshot?.snapshotId : snapshotId;
  if (acceptedBackend.kind === 'renderer' && !acceptedSnapshots.has(snapshot)) throw new ComparisonError('renderer attempts require a snapshot returned by freezeSnapshot in this process', 'wrong-snapshot-identity');
  if (!/^[a-f0-9]{64}$/.test(boundSnapshotId ?? '')) throw new ComparisonError('attempt needs a full snapshot identity', 'wrong-snapshot-identity');
  const normalizedRoot = path.resolve(attemptRoot);
  const normalizedScratch = scratchPaths.map(item => {
    if (!path.isAbsolute(item)) throw new ComparisonError('scratch paths must be absolute', 'invalid-attempt');
    return requireInside(normalizedRoot, path.resolve(item), false);
  });
  if (new Set(normalizedScratch).size !== normalizedScratch.length) throw new ComparisonError('scratch paths must be unique', 'invalid-attempt');
  if (normalizedScratch.some((item, index) => normalizedScratch.some((other, otherIndex) => index !== otherIndex && item.startsWith(`${other}${path.sep}`)))) throw new ComparisonError('scratch paths may not overlap', 'invalid-attempt');
  const normalizedOutput = outputPath === null ? null : path.resolve(outputPath);
  if (acceptedBackend.kind === 'renderer' && (!normalizedOutput || !path.isAbsolute(outputPath))) throw new ComparisonError('renderer attempts require an absolute output path', 'invalid-attempt');
  if (acceptedBackend.kind === 'fake' && normalizedOutput) throw new ComparisonError('fake attempts may not declare renderer output', 'invalid-attempt');
  if (normalizedOutput) requireInside(normalizedRoot, normalizedOutput, false);
  if (normalizedOutput && normalizedScratch.some(item => normalizedOutput === item || normalizedOutput.startsWith(`${item}${path.sep}`))) throw new ComparisonError('output may not be inside cleanable scratch', 'invalid-attempt');
  return freezeValue({ version: 1, id, snapshotId: boundSnapshotId, backend: acceptedBackend, attemptRoot: normalizedRoot, scratchPaths: normalizedScratch, outputPath: normalizedOutput, status: 'running', startedAt: new Date().toISOString(), terminalInventory: null, outputReceipt: null, cleanup: null });
}

async function inventoryPath(item, kind) {
  try {
    const details = await lstat(item);
    const record = { path: item, kind, exists: true, entryType: details.isFile() ? 'file' : details.isDirectory() ? 'directory' : details.isSymbolicLink() ? 'symlink' : 'other', bytes: details.size };
    if (kind === 'output' && details.isFile()) record.sha256 = await fileHash(item);
    return record;
  } catch (error) {
    if (error.code === 'ENOENT') return { path: item, kind, exists: false, entryType: null, bytes: null };
    throw error;
  }
}

async function validateOwnedPaths(attempt) {
  let rootDetails;
  try { rootDetails = await lstat(attempt.attemptRoot); } catch { throw new ComparisonError('attempt root must exist before inventory', 'invalid-attempt'); }
  if (!rootDetails.isDirectory() || rootDetails.isSymbolicLink()) throw new ComparisonError('attempt root must be an owned directory', 'invalid-attempt');
  const rootReal = await realpath(attempt.attemptRoot);
  for (const candidate of [...attempt.scratchPaths, ...(attempt.outputPath ? [attempt.outputPath] : [])]) {
    requireInside(attempt.attemptRoot, candidate, false);
    try {
      const details = await lstat(candidate);
      const physical = details.isSymbolicLink() ? await realpath(path.dirname(candidate)) : await realpath(candidate);
      requireInside(rootReal, physical);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      const parentReal = await realpath(path.dirname(candidate));
      requireInside(rootReal, parentReal);
    }
  }
  return { path: attempt.attemptRoot, kind: 'attempt-root', exists: true, entryType: 'directory', realpath: rootReal, dev: rootDetails.dev, ino: rootDetails.ino };
}

export async function inventoryAttempt(attempt) {
  if (attempt.status !== 'running') throw new ComparisonError('only a running attempt can be inventoried for completion', 'invalid-attempt-transition');
  const rootIdentity = await validateOwnedPaths(attempt);
  const inventory = await Promise.all([...attempt.scratchPaths.map(item => inventoryPath(item, 'scratch')), ...(attempt.outputPath ? [inventoryPath(attempt.outputPath, 'output')] : [])]);
  return freezeValue([rootIdentity, ...inventory]);
}

export async function finishAttempt(attempt, { status }) {
  if (attempt.status !== 'running' || !['completed', 'failed', 'interrupted'].includes(status)) throw new ComparisonError('invalid attempt terminal transition', 'invalid-attempt-transition');
  const terminalInventory = await inventoryAttempt(attempt);
  let outputReceipt = null;
  if (status === 'completed' && attempt.backend.kind === 'renderer') {
    const output = terminalInventory.find(item => item.kind === 'output');
    if (!output?.exists || output.entryType !== 'file' || !output.sha256) throw new ComparisonError('completed renderer attempt requires its actual owned output', 'missing-output-receipt');
    outputReceipt = { status: 'completed', path: output.path, entryType: output.entryType, bytes: output.bytes, sha256: output.sha256, snapshotId: attempt.snapshotId, backend: { identity: attempt.backend.identity, version: attempt.backend.version } };
  }
  if (status !== 'completed' && outputReceipt) throw new ComparisonError('a non-completed attempt may not own a completed output receipt', 'invalid-output-receipt');
  return freezeValue({ ...attempt, status, terminalInventory, outputReceipt, endedAt: new Date().toISOString(), evidenceVerdict: attempt.backend.kind === 'fake' ? 'fake lifecycle only; no renderer or performance verdict' : null });
}

export async function cleanupAttemptScratch(attempt) {
  if (!['completed', 'failed', 'interrupted'].includes(attempt.status) || !Array.isArray(attempt.terminalInventory)) throw new ComparisonError('cleanup requires a terminal inventory', 'invalid-attempt-transition');
  const currentRoot = await validateOwnedPaths({ ...attempt, status: 'running' });
  const terminalRoot = attempt.terminalInventory.find(item => item.kind === 'attempt-root');
  if (!terminalRoot || terminalRoot.realpath !== currentRoot.realpath || terminalRoot.dev !== currentRoot.dev || terminalRoot.ino !== currentRoot.ino) throw new ComparisonError('attempt root changed after terminal inventory', 'invalid-attempt-transition');
  for (const scratchPath of attempt.scratchPaths) {
    requireInside(attempt.attemptRoot, scratchPath, false);
    if (attempt.outputPath && (attempt.outputPath === scratchPath || attempt.outputPath.startsWith(`${scratchPath}${path.sep}`))) throw new ComparisonError('cleanup cannot own the output path', 'invalid-attempt');
    if (!attempt.terminalInventory.some(item => item.kind === 'scratch' && item.path === scratchPath)) throw new ComparisonError('cleanup path is missing from terminal inventory', 'invalid-attempt-transition');
  }
  await Promise.all(attempt.scratchPaths.map(item => rm(item, { recursive: true, force: true })));
  return freezeValue({ ...attempt, cleanup: { status: 'completed', removedScratchPaths: attempt.scratchPaths, completedAt: new Date().toISOString() } });
}

export function measurementSummary(fixtureId, backend = { identity: 'fake', version: 'no-renderer' }) {
  if (!Object.hasOwn(EXPECTED_FIXTURES, fixtureId) || !backend || typeof backend.identity !== 'string' || typeof backend.version !== 'string') throw new ComparisonError('measurement summary needs a known fixture and backend identity', 'invalid-measurement');
  return { schemaVersion: 1, fixtureId, machine: { model: 'unspecified', arch: process.arch, chip: 'unspecified' }, osBuild: 'unspecified', toolPins: { node: process.version }, backend, renderSettings: { verdict: backend.identity === 'fake' ? 'fake backend; no renderer or performance verdict' : 'adapter must replace with measured settings' }, runKind: 'cold', wallTimeSeconds: null, peakRssBytes: null, seekLatenciesMs: [], firstPreviewFrameSeconds: null, outputSha256: null, probeSummary: null, checks: [{ id: 'renderer', status: 'not_run', detail: 'No renderer was run by the shared harness.' }], failures: [], rawRuns: [] };
}
