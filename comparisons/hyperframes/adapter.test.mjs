import assert from 'node:assert/strict';
import test from 'node:test';
import {freezeSnapshot} from '../common/index.mjs';
import {framePayload, HyperframesAdapter, ownedProcessTree} from './adapter.mjs';

const fixtureRoot = process.env.FIXTURE_ROOT;
const acceptedCommit = '8a3daf1978093a3d67649b8f3779a9aa15fab876';

test('M browser payload uses accepted frame state and media element kinds', async () => {
  assert.ok(fixtureRoot);
  const snapshot = await freezeSnapshot({acceptedCommit, fixtureRoot});
  const payload = framePayload(snapshot, 'M');
  assert.equal(payload.frames.length, 480);
  assert.equal(payload.sources.harborCorrupt, undefined);
  assert.equal(payload.sources.lpMatchedVideo.element, 'video');
  assert.equal(payload.sources.lpMismatchStill.element, 'image');
  assert.deepEqual(payload.frames[150].pictureLayers[0].geometry.border, {color: '#f4f1ea', width: 0.003});
  assert.equal(Object.keys(payload.sources).length, 12);
  assert.ok(Math.max(...payload.frames.map((frame) => frame.pictureLayers.length)) >= 4);
});

test('cancellation is attempt-scoped and restart requires a fresh attempt id', () => {
  const adapter = new HyperframesAdapter({browser: 'browser', fixtureRoot: 'fixture-root', runtime: 'runtime'});
  const controller = new AbortController();
  adapter.controllers.set('m-cold-3', controller);
  adapter.cancel('m-cold-3');
  assert.equal(controller.signal.aborted, true);
  assert.throws(() => adapter.cancel('unknown'), /Unknown active attempt/);
  assert.throws(() => adapter.restart({fixtureId: 'M', previousAttemptId: 'm-cold-3', attemptRoot: 'm-cold-3'}), /new attempt id/);
});

test('process sampling excludes unrelated processes and retains descendants', () => {
  const rows = [{pid: 10, ppid: 1}, {pid: 11, ppid: 10}, {pid: 12, ppid: 11}, {pid: 13, ppid: 1}];
  assert.deepEqual(ownedProcessTree(rows, 10).map((row) => row.pid), [10, 11, 12]);
});
