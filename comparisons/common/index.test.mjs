import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { access, mkdir, mkdtemp, readFile, rename, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { assertSnapshotIdentity, cleanupAttemptScratch, comparisonTreatment, ComparisonError, createAttempt, finishAttempt, frameState, freezeSnapshot, hydrateFrameState, measurementSummary, reserveStorage } from './index.mjs';

const fixtureRoot = process.env.TAKEFORM_FIXTURE_ROOT;
const acceptedCommit = '8a3daf1978093a3d67649b8f3779a9aa15fab876';
const temporaryRoots = [];
const sourceBytes = 'diagnostic source bytes';
const sourceHash = createHash('sha256').update(sourceBytes).digest('hex');
let snapshot;

test.before(async () => {
  if (!fixtureRoot) throw new Error('set TAKEFORM_FIXTURE_ROOT to the local accepted fixture root');
  snapshot = await freezeSnapshot({ fixtureRoot, acceptedCommit });
});

test.after(async () => {
  await Promise.all(temporaryRoots.map(root => rm(root, { recursive: true, force: true })));
});

async function diagnosticFixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'comparison-'));
  temporaryRoots.push(root);
  const registry = JSON.parse(await readFile(path.join(fixtureRoot, 'registry.json'), 'utf8'));
  await writeFile(path.join(root, 'registry.json'), JSON.stringify(registry));
  for (const id of ['M', 'T', 'L']) {
    await mkdir(path.join(root, id), { recursive: true });
    await writeFile(path.join(root, id, 'source.bin'), sourceBytes);
    const manifest = structuredClone(snapshot._manifests[id].manifest);
    if (id === 'T') manifest.canonicalPlan.wordCorrections = [];
    for (const source of manifest.sources) {
      source.path = 'source.bin';
      source.sha256 = sourceHash;
    }
    await writeFile(path.join(root, id, 'manifest.json'), JSON.stringify(manifest));
  }
  await writeFile(path.join(root, 'T', 'words-take1.json'), JSON.stringify({ isHumanGroundTruth: false, words: [{ id: 'take1-word-000', sourceStartSeconds: 0.1, acousticTailEndSeconds: 0.2 }, { id: 'take1-word-001', sourceStartSeconds: 34.1, acousticTailEndSeconds: 34.2 }] }));
  await writeFile(path.join(root, 'T', 'words-take2.json'), JSON.stringify({ isHumanGroundTruth: false, words: [{ id: 'take2-word-000', sourceStartSeconds: 10.1, acousticTailEndSeconds: 10.2 }, { id: 'take2-word-001', sourceStartSeconds: 20.1, acousticTailEndSeconds: 20.2 }] }));
  return root;
}

async function mutateManifest(root, id, mutate) {
  const file = path.join(root, id, 'manifest.json');
  const manifest = JSON.parse(await readFile(file, 'utf8'));
  mutate(manifest);
  await writeFile(file, JSON.stringify(manifest));
}

const rationalCompare = (left, right) => BigInt(left.ticks) * BigInt(right.timescale) - BigInt(right.ticks) * BigInt(left.timescale);
const rationalAdd = (left, right) => ({ ticks: Number(BigInt(left.ticks) * BigInt(right.timescale) + BigInt(right.ticks) * BigInt(left.timescale)), timescale: left.timescale * right.timescale });

test('keeps the browser frame-state module free of Node dependencies', async () => {
  const source = await readFile(new URL('./frame-state.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /node:|process\.|createHash|readFile/);
  const browserSnapshot = hydrateFrameState({ snapshotId: snapshot.snapshotId, manifests: snapshot._manifests, treatment: snapshot._treatment });
  assert.deepEqual(frameState(browserSnapshot, 'T', 270), frameState(snapshot, 'T', 270));
});

test('freezes accepted manifests, source bytes, measured speech files, and treatment identity', async () => {
  assert.match(snapshot.snapshotId, /^[a-f0-9]{64}$/);
  assert.equal(snapshot.sources.filter(source => source.status === 'declared-unused-corrupt').length, 1);
  assert.equal(snapshot.supportingFiles.length, 2);
  assert.ok(snapshot._manifests.T.speechRanges.length > 100);
  const changed = structuredClone(comparisonTreatment);
  changed.T.caption.fontSizePx += 1;
  const root = await diagnosticFixture();
  const before = await freezeSnapshot({ fixtureRoot: root, acceptedCommit, treatment: comparisonTreatment });
  const after = await freezeSnapshot({ fixtureRoot: root, acceptedCommit, treatment: changed });
  assert.notEqual(before.snapshotId, after.snapshotId);
  assert.throws(() => assertSnapshotIdentity(after, before.snapshotId), /identity/);
});

test('returns deterministic ordered M layers and exact accepted frame bounds', () => {
  assert.deepEqual(frameState(snapshot, 'M', 90), frameState(snapshot, 'M', 90));
  assert.equal(frameState(snapshot, 'M', 0).pictureLayers.length, 1);
  const overlap = frameState(snapshot, 'M', 150).pictureLayers;
  assert.deepEqual(overlap.map(layer => [layer.occurrenceId, layer.layer]), [['oWorkshop', 1], ['oHill', 0], ['oClip24', 2]]);
  assert.ok(overlap.every(layer => layer.geometry && layer.sourceTime));
  assert.equal(frameState(snapshot, 'M', 479).frame, 479);
  assert.equal(frameState(snapshot, 'T', 2699).frame, 2699);
  assert.equal(frameState(snapshot, 'L', 43156).frame, 43156);
  for (const [id, frame] of [['M', 480], ['T', 2700], ['L', 43157]]) assert.throws(() => frameState(snapshot, id, frame), /outside/);
});

test('maps every T cut and caption boundary with exact source identities', () => {
  const manifest = snapshot._manifests.T.manifest;
  for (const occurrence of manifest.canonicalPlan.occurrences.filter(item => item.role === 'picture' || item.role === 'dialogue')) {
    const frame = occurrence.outputRange.start.ticks;
    const state = frameState(snapshot, 'T', frame);
    const layers = occurrence.role === 'picture' ? state.pictureLayers : state.audio.roles;
    const layer = layers.find(item => item.occurrenceId === occurrence.id);
    assert.equal(layer.sourceId, occurrence.sourceId);
    assert.equal(rationalCompare(layer.sourceTime, occurrence.sourceRange.start), 0n);
    assert.deepEqual(layer.geometry, { x: 0, y: 0, width: 1, height: 1, rotationDegrees: 0, fit: 'cover' });
  }
  for (const caption of manifest.expected.captions) {
    const start = Math.ceil(caption.outputRange.start.ticks * 30 / caption.outputRange.start.timescale);
    const endTime = rationalAdd(caption.outputRange.start, caption.outputRange.duration);
    const end = Math.ceil(endTime.ticks * 30 / endTime.timescale);
    assert.equal(frameState(snapshot, 'T', start).caption.text, caption.text);
    if (start > 0) assert.notEqual(frameState(snapshot, 'T', start - 1).caption?.text, caption.text);
    if (end < 2700) assert.notEqual(frameState(snapshot, 'T', end).caption?.text, caption.text);
  }
});

test('projects measured speech gaps into a linear-dB music envelope', () => {
  const music = frame => frameState(snapshot, 'T', frame).audio.roles.find(role => role.role === 'music');
  assert.equal(music(251).gainDb, -24);
  assert.ok(music(252).gainDb > -24 && music(252).gainDb < -16);
  assert.equal(music(270).gainDb, -16);
  assert.equal(music(270).phase, 'gap');
  assert.equal(music(314).gainDb, -24);
  assert.equal(music(270).interpolation, 'linear-db');
  assert.equal(music(270).sourceId, 'music');
  assert.equal(rationalCompare(music(270).sourceTime, { ticks: 9, timescale: 1 }), 0n);
  assert.deepEqual(frameState(snapshot, 'T', 270).audio.normalization, { targetIntegratedLufs: -16, maxTruePeakDbtp: -1, actualBackendMixing: null, explicitNormalizationStage: null });
});

test('keeps L chapter audio continuous and bounded through every join', () => {
  const manifest = snapshot._manifests.L.manifest;
  const transitions = manifest.canonicalPlan.occurrences.filter(item => item.role === 'transition');
  const assertBoundedAudio = roles => {
    assert.ok(roles.length > 0);
    for (const role of roles) {
      assert.ok(role.sourceTime && role.sourceRange);
      assert.ok(rationalCompare(role.sourceTime, role.sourceRange.start) >= 0n);
      assert.ok(rationalCompare(role.sourceTime, rationalAdd(role.sourceRange.start, role.sourceRange.duration)) < 0n);
    }
  };
  for (const frame of [0, 43156]) {
    const state = frameState(snapshot, 'L', frame);
    const roles = state.audio.roles;
    assert.equal(roles.length, 1);
    assert.equal(roles[0].gain, 1);
    assert.equal(roles[0].occurrenceId, state.pictureLayers[0].occurrenceId);
    assert.deepEqual(roles[0].sourceRange, state.pictureLayers[0].sourceRange);
    assert.equal(rationalCompare(roles[0].sourceTime, state.pictureLayers[0].sourceTime), 0n);
    assertBoundedAudio(roles);
  }
  for (const transition of transitions) {
    const start = transition.outputRange.start.ticks / 1001;
    const end = start + 24;
    let previousTimes = null;
    for (let frame = start; frame < end; frame += 1) {
      const layers = frameState(snapshot, 'L', frame).pictureLayers;
      const audio = frameState(snapshot, 'L', frame).audio;
      assert.equal(layers.length, 2);
      assert.equal(audio.roles.length, 2);
      assert.equal(audio.roles[0].gain, audio.transition.audio.outgoingGain);
      assert.equal(audio.roles[1].gain, audio.transition.audio.incomingGain);
      assertBoundedAudio(audio.roles);
      for (const layer of layers) {
        assert.ok(layer.sourceTime && layer.sourceRange && layer.geometry);
        assert.ok(rationalCompare(layer.sourceTime, layer.sourceRange.start) >= 0n);
        assert.ok(rationalCompare(layer.sourceTime, rationalAdd(layer.sourceRange.start, layer.sourceRange.duration)) < 0n);
      }
      if (previousTimes) for (let index = 0; index < 2; index += 1) assert.ok(rationalCompare(layers[index].sourceTime, previousTimes[index]) > 0n);
      previousTimes = layers.map(layer => layer.sourceTime);
    }
    for (const frame of [start - 1, end]) {
      const state = frameState(snapshot, 'L', frame);
      const audio = state.audio;
      assert.equal(audio.transition, undefined);
      assert.equal(audio.roles.length, 1);
      assert.equal(audio.roles[0].gain, 1);
      assert.equal(audio.roles[0].occurrenceId, state.pictureLayers[0].occurrenceId);
      assert.deepEqual(audio.roles[0].sourceRange, state.pictureLayers[0].sourceRange);
      assert.equal(rationalCompare(audio.roles[0].sourceTime, state.pictureLayers[0].sourceTime), 0n);
      assertBoundedAudio(audio.roles);
    }
  }
  const first = frameState(snapshot, 'L', 2865);
  assert.equal(rationalCompare(first.pictureLayers[1].sourceRange.start, { ticks: 12012, timescale: 24000 }), 0n);
  assert.equal(rationalCompare(frameState(snapshot, 'L', 2877).pictureLayers[1].sourceTime, { ticks: 24024, timescale: 24000 }), 0n);
});

test('rejects invalid fixture schemas, missing fixture identities, unsafe timing, and path escape', async () => {
  const missingField = await diagnosticFixture();
  await mutateManifest(missingField, 'M', manifest => { delete manifest.generator; });
  await assert.rejects(freezeSnapshot({ fixtureRoot: missingField, acceptedCommit }), error => error.code === 'invalid-manifest');

  const missingFixture = await diagnosticFixture();
  const registryFile = path.join(missingFixture, 'registry.json');
  const registry = JSON.parse(await readFile(registryFile, 'utf8'));
  registry.fixtures = registry.fixtures.filter(entry => entry.id !== 'T');
  await writeFile(registryFile, JSON.stringify(registry));
  await assert.rejects(freezeSnapshot({ fixtureRoot: missingFixture, acceptedCommit }), error => error.code === 'invalid-registry');

  const unsafe = await diagnosticFixture();
  await mutateManifest(unsafe, 'M', manifest => { manifest.canonicalPlan.occurrences[0].sourceRange.start.ticks = Number.MAX_SAFE_INTEGER + 1; });
  await assert.rejects(freezeSnapshot({ fixtureRoot: unsafe, acceptedCommit }), error => error.code === 'unsafe-rational');

  const escaped = await diagnosticFixture();
  await mutateManifest(escaped, 'M', manifest => { manifest.sources.find(source => source.kind === 'corrupt').path = '../../etc/passwd'; });
  await assert.rejects(freezeSnapshot({ fixtureRoot: escaped, acceptedCommit }), error => error.code === 'path-escape');
});

test('rejects changed bytes, selected corrupt media, unknown sources, and handle overflow', async () => {
  const changed = await diagnosticFixture();
  await writeFile(path.join(changed, 'M', 'source.bin'), 'changed');
  await assert.rejects(freezeSnapshot({ fixtureRoot: changed, acceptedCommit }), /hash mismatch/);

  const corrupt = await diagnosticFixture();
  await mutateManifest(corrupt, 'M', manifest => { manifest.sources.find(source => source.id === 'harbor').kind = 'corrupt'; });
  await assert.rejects(freezeSnapshot({ fixtureRoot: corrupt, acceptedCommit }), error => error.code === 'selected-corrupt-source');

  const unknown = await diagnosticFixture();
  await mutateManifest(unknown, 'M', manifest => { manifest.canonicalPlan.occurrences[0].sourceId = 'missing'; });
  await assert.rejects(freezeSnapshot({ fixtureRoot: unknown, acceptedCommit }), error => error.code === 'unknown-source');

  const overflow = await diagnosticFixture();
  await mutateManifest(overflow, 'M', manifest => { manifest.sources[0].duration = { ticks: 0, timescale: 1 }; manifest.canonicalPlan.occurrences[0].sourceRange.duration = { ticks: 1, timescale: 1 }; });
  await assert.rejects(freezeSnapshot({ fixtureRoot: overflow, acceptedCommit }), error => error.code === 'source-handle-overflow');
});

test('rejects symlinks and contradictory treatments', async () => {
  const linked = await diagnosticFixture();
  await symlink(path.join(linked, 'M', 'source.bin'), path.join(linked, 'M', 'linked.bin'));
  await mutateManifest(linked, 'M', manifest => { manifest.sources[0].path = 'linked.bin'; });
  await assert.rejects(freezeSnapshot({ fixtureRoot: linked, acceptedCommit }), error => error.code === 'symlink-escape');

  const root = await diagnosticFixture();
  for (const mutate of [
    treatment => { treatment.L.transitionFrames = 12; },
    treatment => { treatment.T.caption.maxLines = 99; },
    treatment => { treatment.T.caption.safeMargin = 2; },
    treatment => { treatment.T.audio.attackMs = -1; },
  ]) {
    const treatment = structuredClone(comparisonTreatment);
    mutate(treatment);
    await assert.rejects(freezeSnapshot({ fixtureRoot: root, acceptedCommit, treatment }), error => error.code === 'invalid-treatment');
  }
});

test('requires conservative closed storage reservations', () => {
  assert.throws(() => reserveStorage({ route: 'unknown', width: 1920, height: 1080, frameCount: 480, expectedOutputBytes: 1, freeBytes: 2 ** 40 }), /route/);
  assert.throws(() => reserveStorage({ route: 'disk', width: 1920, height: 1080, frameCount: 480, expectedOutputBytes: -1, freeBytes: 2 ** 40 }), /expectedOutputBytes/);
  assert.throws(() => reserveStorage({ route: 'streaming', width: 1920, height: 1080, frameCount: 480, expectedOutputBytes: 1, decodeCacheBytes: 0, pipelineBufferBytes: 1, runtimeFreeFloorBytes: 1, freeBytes: 2 ** 40 }), /decodeCacheBytes/);
  assert.throws(() => reserveStorage({ route: 'disk', width: 1920, height: 1080, frameCount: 480, expectedOutputBytes: 1, freeBytes: 1 }), /insufficient/);
  const disk = reserveStorage({ route: 'disk', width: 1920, height: 1080, frameCount: 480, scale: 0.5, expectedOutputBytes: 100, freeBytes: 2 ** 40 });
  assert.equal(disk.frameBytes, 480 * 960 * 540 * 4);
  const streaming = reserveStorage({ route: 'streaming', width: 1920, height: 1080, frameCount: 480, expectedOutputBytes: 30, decodeCacheBytes: 10, pipelineBufferBytes: 20, runtimeFreeFloorBytes: 40, freeBytes: 100 });
  assert.equal(streaming.requiredBytes, 100);
});

test('binds terminal evidence and cleanup to attempt-owned paths', async () => {
  const parent = await mkdtemp(path.join(os.tmpdir(), 'comparison-attempts-'));
  temporaryRoots.push(parent);
  const attemptRoot = path.join(parent, 'real');
  const scratch = path.join(attemptRoot, 'scratch');
  await mkdir(scratch, { recursive: true });
  const output = path.join(attemptRoot, 'output.mp4');
  await writeFile(output, 'rendered bytes');
  await writeFile(path.join(scratch, 'frame'), 'frame');
  const real = createAttempt({ id: 'real', snapshot, backend: { kind: 'renderer', identity: 'remotion', version: 'test' }, attemptRoot, scratchPaths: [scratch], outputPath: output });
  const completed = await finishAttempt(real, { status: 'completed' });
  assert.equal(completed.outputReceipt.sha256, createHash('sha256').update('rendered bytes').digest('hex'));
  assert.equal(completed.outputReceipt.snapshotId, snapshot.snapshotId);
  assert.equal(completed.outputReceipt.path, output);
  const cleaned = await cleanupAttemptScratch(completed);
  assert.equal(cleaned.cleanup.status, 'completed');
  await assert.rejects(access(scratch));
  await access(output);

  const fakeRoot = path.join(parent, 'fake');
  const fakeScratch = path.join(fakeRoot, 'scratch');
  await mkdir(fakeScratch, { recursive: true });
  const fake = createAttempt({ id: 'fake', snapshotId: snapshot.snapshotId, backend: { kind: 'fake', identity: 'fake', version: 'lifecycle-only' }, attemptRoot: fakeRoot, scratchPaths: [fakeScratch] });
  const fakeComplete = await finishAttempt(fake, { status: 'completed' });
  assert.equal(fakeComplete.outputReceipt, null);
  assert.match(fakeComplete.evidenceVerdict, /no renderer/);
  assert.throws(() => createAttempt({ id: 'spoof', snapshotId: snapshot.snapshotId, backend: { kind: 'renderer', identity: 'remotion', version: 'test' }, attemptRoot: path.join(parent, 'spoof'), scratchPaths: ['/tmp/outside'], outputPath: '/etc/passwd' }), /snapshot returned by freezeSnapshot/);

  const interruptedRoot = path.join(parent, 'interrupted');
  const interruptedScratch = path.join(interruptedRoot, 'scratch');
  const interruptedOutput = path.join(interruptedRoot, 'output.mp4');
  await mkdir(interruptedScratch, { recursive: true });
  await writeFile(interruptedOutput, 'partial');
  const interrupted = await finishAttempt(createAttempt({ id: 'interrupted', snapshot, backend: { kind: 'renderer', identity: 'hyperframes', version: 'test' }, attemptRoot: interruptedRoot, scratchPaths: [interruptedScratch], outputPath: interruptedOutput }), { status: 'interrupted' });
  assert.equal(interrupted.outputReceipt, null);
  assert.equal(interrupted.terminalInventory.find(item => item.kind === 'output').exists, true);

  const swappedRoot = path.join(parent, 'swapped');
  const swappedScratch = path.join(swappedRoot, 'scratch');
  await mkdir(swappedScratch, { recursive: true });
  const swapped = await finishAttempt(createAttempt({ id: 'swapped', snapshotId: snapshot.snapshotId, backend: { kind: 'fake', identity: 'fake', version: 'lifecycle-only' }, attemptRoot: swappedRoot, scratchPaths: [swappedScratch] }), { status: 'completed' });
  await rename(swappedRoot, `${swappedRoot}-old`);
  await mkdir(swappedScratch, { recursive: true });
  await writeFile(path.join(swappedScratch, 'foreign'), 'another attempt');
  await assert.rejects(cleanupAttemptScratch(swapped), /root changed/);
  await access(path.join(swappedScratch, 'foreign'));
});

test('keeps fake measurement summaries schema-shaped and explicit', () => {
  const summary = measurementSummary('M');
  assert.equal(summary.backend.identity, 'fake');
  assert.equal(summary.checks[0].status, 'not_run');
  assert.equal(summary.wallTimeSeconds, null);
  assert.throws(() => measurementSummary('X'), /known fixture/);
});
