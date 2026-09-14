import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { assertSnapshotIdentity, comparisonTreatment, ComparisonError, createAttempt, finishAttempt, frameState, freezeSnapshot, hydrateFrameState, reserveStorage } from './index.mjs';

const fixtureRoot = process.env.TAKEFORM_FIXTURE_ROOT;
const commit = '8a3daf1978093a3d67649b8f3779a9aa15fab876';
const temporaryRoots = [];
let snapshot;

test.before(async () => {
  if (!fixtureRoot) throw new Error('set TAKEFORM_FIXTURE_ROOT to the local accepted fixture root');
  snapshot = await freezeSnapshot({ fixtureRoot, acceptedCommit: commit });
});

test.after(async () => {
  await Promise.all(temporaryRoots.map(root => rm(root, { recursive: true, force: true })));
});

async function isolatedMFixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'comparison-'));
  temporaryRoots.push(root);
  await mkdir(path.join(root, 'M', 'media'), { recursive: true });
  await writeFile(path.join(root, 'M', 'media', 'good'), 'good');
  await writeFile(path.join(root, 'registry.json'), JSON.stringify({ fixtures: [{ path: 'M/manifest.json' }] }));
  const manifest = structuredClone(snapshot._manifests.M.manifest);
  manifest.sources = [manifest.sources[0]];
  manifest.sources[0].path = 'media/good';
  manifest.sources[0].sha256 = '770e607624d689265ca6c44884d0807d9b054d23c473c106c72be9de08b7376c';
  manifest.canonicalPlan.occurrences = [manifest.canonicalPlan.occurrences[0]];
  const treatment = structuredClone(comparisonTreatment);
  treatment.M.panels = { oHarbor: treatment.M.panels.oHarbor };
  await writeFile(path.join(root, 'M', 'manifest.json'), JSON.stringify(manifest));
  return { root, manifest, treatment };
}

test('keeps the browser frame-state module free of Node dependencies', async () => {
  const source = await readFile(new URL('./frame-state.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /node:|process\.|createHash|readFile/);
  const browserSnapshot = hydrateFrameState({ snapshotId: snapshot.snapshotId, manifests: snapshot._manifests, treatment: snapshot._treatment });
  assert.deepEqual(frameState(browserSnapshot, 'M', 60), frameState(snapshot, 'M', 60));
});

test('freezes an identity that includes the accepted commit, manifests, source hashes, and treatment', async () => {
  assert.match(snapshot.snapshotId, /^[a-f0-9]{64}$/);
  assert.equal(snapshot.sources.filter(source => source.status === 'declared-unused-corrupt').length, 1);
  const changed = structuredClone(comparisonTreatment);
  changed.T.caption.fontSizePx += 1;
  const changedSnapshot = await freezeSnapshot({ fixtureRoot, acceptedCommit: commit, treatment: changed });
  assert.notEqual(snapshot.snapshotId, changedSnapshot.snapshotId);
});

test('returns deterministic first, overlap, and last M frames with distinct panels', () => {
  assert.deepEqual(frameState(snapshot, 'M', 90), frameState(snapshot, 'M', 90));
  assert.equal(frameState(snapshot, 'M', 0).pictureLayers.length, 1);
  const overlap = frameState(snapshot, 'M', 60);
  assert.ok(overlap.pictureLayers.length > 1);
  assert.notDeepEqual(overlap.pictureLayers[0].geometry, overlap.pictureLayers[1].geometry);
  assert.equal(frameState(snapshot, 'M', 479).frame, 479);
  assert.throws(() => frameState(snapshot, 'M', 480), ComparisonError);
});

test('maps every T cut, author chapter, and caption transition', () => {
  for (const [frame, chapter] of [[0, 'Setup'], [360, 'The cut'], [1800, 'Close'], [2100, 'Close'], [2699, 'Close']]) {
    assert.equal(frameState(snapshot, 'T', frame).frame, frame);
    assert.equal(frameState(snapshot, 'T', frame).authorChapter, chapter);
  }
  for (const caption of snapshot._manifests.T.manifest.expected.captions) {
    const frame = Math.ceil(caption.outputRange.start.ticks * 30 / caption.outputRange.start.timescale);
    assert.equal(frameState(snapshot, 'T', frame).caption.text, caption.text);
  }
  assert.equal(frameState(snapshot, 'T', 360).audio.roles.find(role => role.role === 'music').gainDb, -24);
});

test('maps every L join and preserves the exact terminal frame boundary', () => {
  const manifest = snapshot._manifests.L.manifest;
  for (const boundary of manifest.expected.chapterBoundaries.slice(1, -1)) {
    const frame = Math.floor(boundary.outputTime.ticks / 1001);
    const state = frameState(snapshot, 'L', frame);
    assert.equal(state.pictureLayers.length, 2);
    assert.equal(state.pictureLayers[1].sourceRange.start.ticks, 0);
    assert.equal(state.audio.transition.boundaryIndex, boundary.index);
  }
  assert.equal(frameState(snapshot, 'L', 43156).frame, 43156);
  assert.throws(() => frameState(snapshot, 'L', 43157), /outside/);
});

test('rejects a selected source whose bytes change', async () => {
  const { root, treatment } = await isolatedMFixture();
  await freezeSnapshot({ fixtureRoot: root, acceptedCommit: commit, treatment });
  await writeFile(path.join(root, 'M', 'media', 'good'), 'changed');
  await assert.rejects(freezeSnapshot({ fixtureRoot: root, acceptedCommit: commit, treatment }), /hash mismatch/);
});

test('rejects a selected source declared corrupt', async () => {
  const { root, manifest, treatment } = await isolatedMFixture();
  manifest.sources[0].kind = 'corrupt';
  await writeFile(path.join(root, 'M', 'manifest.json'), JSON.stringify(manifest));
  await assert.rejects(freezeSnapshot({ fixtureRoot: root, acceptedCommit: commit, treatment }), /declared corrupt/);
});

test('rejects traversal and a symlink escape from the supplied fixture root', async () => {
  const { root, manifest, treatment } = await isolatedMFixture();
  manifest.sources[0].path = '../../outside';
  await writeFile(path.join(root, 'M', 'manifest.json'), JSON.stringify(manifest));
  await assert.rejects(freezeSnapshot({ fixtureRoot: root, acceptedCommit: commit, treatment }), /escapes|missing/);
  const outside = await mkdtemp(path.join(os.tmpdir(), 'comparison-outside-'));
  temporaryRoots.push(outside);
  await writeFile(path.join(outside, 'outside'), 'outside');
  await symlink(path.join(outside, 'outside'), path.join(root, 'M', 'media', 'link'));
  manifest.sources[0].path = 'media/link';
  await writeFile(path.join(root, 'M', 'manifest.json'), JSON.stringify(manifest));
  await assert.rejects(freezeSnapshot({ fixtureRoot: root, acceptedCommit: commit, treatment }), /symlink/);
});

test('rejects an invalid rate and a wrong snapshot identity', async () => {
  const { root, manifest, treatment } = await isolatedMFixture();
  manifest.canonicalPlan.outputFrameRate.num = 0;
  await writeFile(path.join(root, 'M', 'manifest.json'), JSON.stringify(manifest));
  await assert.rejects(freezeSnapshot({ fixtureRoot: root, acceptedCommit: commit, treatment }), /frame rate/);
  assert.throws(() => assertSnapshotIdentity(snapshot, 'wrong'), /identity/);
});

test('rejects an unknown selected source and a source range beyond its handle', async () => {
  const { root, manifest, treatment } = await isolatedMFixture();
  manifest.canonicalPlan.occurrences[0].sourceId = 'missing';
  await writeFile(path.join(root, 'M', 'manifest.json'), JSON.stringify(manifest));
  await assert.rejects(freezeSnapshot({ fixtureRoot: root, acceptedCommit: commit, treatment }), /unknown source/);

  manifest.canonicalPlan.occurrences[0].sourceId = 'harbor';
  manifest.sources[0].duration = { ticks: 0, timescale: 1 };
  manifest.canonicalPlan.occurrences[0].sourceRange.duration = { ticks: 1, timescale: 1 };
  await writeFile(path.join(root, 'M', 'manifest.json'), JSON.stringify(manifest));
  await assert.rejects(freezeSnapshot({ fixtureRoot: root, acceptedCommit: commit, treatment }), /source handle/);
});

test('rejects an insufficient storage reservation and reports streaming components', () => {
  assert.throws(() => reserveStorage({ route: 'disk', width: 1920, height: 1080, frameCount: 480, freeBytes: 1 }), /insufficient/);
  const streaming = reserveStorage({ route: 'streaming', width: 1920, height: 1080, frameCount: 480, decodeCacheBytes: 10, pipelineBufferBytes: 20, expectedOutputBytes: 30, runtimeFreeFloorBytes: 40, freeBytes: 100 });
  assert.equal(streaming.frameBytes, null);
  assert.equal(streaming.requiredBytes, 100);
});

test('separates completed and interrupted attempt receipts', () => {
  const attempt = createAttempt({ id: 'fake', snapshotId: snapshot.snapshotId, backend: 'fake', declaredPaths: ['/tmp/fake'] });
  assert.throws(() => finishAttempt(attempt, { status: 'completed', terminalInventory: [] }), /receipt/);
  assert.throws(() => finishAttempt(attempt, { status: 'interrupted', terminalInventory: [], outputReceipt: { status: 'completed' } }), /may not own/);
  const interrupted = finishAttempt(attempt, { status: 'interrupted', terminalInventory: [] });
  assert.equal(interrupted.status, 'interrupted');
  assert.equal(interrupted.outputReceipt, null);
  const failed = finishAttempt(createAttempt({ id: 'failed', snapshotId: snapshot.snapshotId, backend: 'fake', declaredPaths: ['/tmp/failed'] }), { status: 'failed', terminalInventory: [] });
  assert.equal(failed.status, 'failed');
});
