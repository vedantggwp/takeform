import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {freezeSnapshot} from '../common/index.mjs';
import {framePayload, HyperframesAdapter, mediaPreparationReceipt, ownedProcessTree} from './adapter.mjs';
import {longFilmSupport, talkingHeadSupport} from './fixture-support.mjs';

const fixtureRoot = process.env.FIXTURE_ROOT;
const derivativeRoot = process.env.DERIVATIVE_ROOT;
const mediaPrepManifest = process.env.MEDIA_PREP_MANIFEST;
const mediaPrepModule = process.env.MEDIA_PREP_MODULE;
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

test('future receipts use the accepted shared validator output shape', async () => {
  assert.ok(fixtureRoot);
  assert.ok(derivativeRoot);
  assert.ok(mediaPrepManifest);
  assert.ok(mediaPrepModule);
  const snapshot = await freezeSnapshot({acceptedCommit, fixtureRoot});
  const loader = await import(pathToFileURL(resolve(mediaPrepModule)).href);
  const manifestBytes = await readFile(mediaPrepManifest);
  const manifest = JSON.parse(manifestBytes.toString('utf8'));
  const entries = await loader.validateManifest(manifest, {derivativeRoot, expectedOriginals: loader.expectedOriginalsFromSnapshot(snapshot, 'M')});
  const receipt = mediaPreparationReceipt(manifestBytes, manifest, entries);
  assert.equal(receipt.semanticManifestDigest, manifest.manifestDigest);
  assert.notEqual(receipt.rawManifestSha256, receipt.semanticManifestDigest);
  assert.deepEqual(receipt.derivativeHashes, entries.map((entry) => ({sourceId: entry.sourceId, sha256: entry.sha256})));
});

test('T support reads corrected caption edges, muted picture sound, and speech from frame state', async () => {
  assert.ok(fixtureRoot);
  const snapshot = await freezeSnapshot({acceptedCommit, fixtureRoot});
  const support = talkingHeadSupport(snapshot);
  assert.deepEqual(support.rate, {num: 30, den: 1});
  assert.equal(support.frameCount, 2700);
  assert.equal(support.pictureAudioMuted, true);
  assert.ok(support.captions.length > 0);
  for (const caption of support.captions) {
    assert.deepEqual(support.stateAt(caption.startFrame).caption, caption.caption);
    assert.notDeepEqual(support.stateAt(caption.endFrame - 1).caption, null);
    if (caption.startFrame > 0) assert.notDeepEqual(support.stateAt(caption.startFrame - 1).caption, caption.caption);
    if (caption.endFrame < support.frameCount) assert.notDeepEqual(support.stateAt(caption.endFrame).caption, caption.caption);
  }
  const dialogue = support.roles.filter((role) => role.role === 'dialogue');
  assert.ok(dialogue.length > 0);
  for (const role of dialogue) {
    assert.deepEqual(support.stateAt(role.startFrame).audio.roles.find((candidate) => candidate.occurrenceId === role.occurrenceId)?.sourceTime, role.sourceTime);
    assert.ok(role.sourceRate);
  }
  assert.ok(support.roles.filter((role) => role.role === 'music').every((role) => role.gainSamples.length > 0));
  const music = support.producerAudioTracks.find((track) => track.sourceId === 'music');
  assert.equal(music.automation.lanes[0].target, 'fx.hf-gain.gain');
  assert.equal(music.fxChain.nodes[0].type, 'gain');
  assert.ok(music.automation.lanes[0].points.length <= 512);
});

test('L support retains rational rate, all chapter labels, both handles at every crossfade, and continuous audio', async () => {
  assert.ok(fixtureRoot);
  const snapshot = await freezeSnapshot({acceptedCommit, fixtureRoot});
  const support = longFilmSupport(snapshot);
  assert.deepEqual(support.rate, {num: 24000, den: 1001});
  assert.equal(support.frameCount, 43157);
  assert.equal(support.chapters.length, 15);
  assert.deepEqual(support.chapters.map((chapter) => chapter.label), Array.from({length: 15}, (_, index) => `chapter${String(index + 1).padStart(2, '0')}`));
  assert.equal(support.crossfades.length, 14);
  for (const crossfade of support.crossfades) {
    assert.equal(crossfade.pictureSourceIds.length, 2);
    assert.deepEqual(crossfade.audioSourceIds, crossfade.pictureSourceIds);
    for (let frame = crossfade.startFrame; frame < crossfade.endFrame; frame += 1) {
      assert.equal(support.stateAt(frame).audio.roles.length, 2);
    }
  }
  assert.ok(support.producerAudioTracks.every((track) => track.automation?.lanes[0].target === 'volume' || track.volume === 1));
  assert.ok(support.producerAudioTracks.every((track) => (track.automation?.lanes[0].points.length ?? 0) <= 512));
  for (let frame = 0; frame < support.frameCount; frame += 1) assert.ok(support.stateAt(frame).audio.roles.length > 0);
});
