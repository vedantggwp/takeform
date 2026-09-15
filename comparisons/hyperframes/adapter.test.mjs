import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp, readFile, readdir, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
import {freezeSnapshot} from '../common/index.mjs';
import {framePayload, HyperframesAdapter, mediaPreparationReceipt, ownedProcessTree} from './adapter.mjs';
import {longFilmSupport, talkingHeadSupport} from './fixture-support.mjs';
import {tlPayload, writeTlProject} from './tl-composition.mjs';

const fixtureRoot = process.env.FIXTURE_ROOT;
const runtime = process.env.TAKEFORM_RUNTIME;
const acceptedCommit = '8a3daf1978093a3d67649b8f3779a9aa15fab876';

async function pinnedPublicParsers(html) {
  assert.ok(runtime, 'TAKEFORM_RUNTIME is required for public producer compilation checks');
  const core = await import(pathToFileURL(join(runtime, 'node_modules/@hyperframes/core/dist/index.js')).href);
  const engine = await import(pathToFileURL(join(runtime, 'node_modules/@hyperframes/engine/dist/index.js')).href);
  const producer = await import(pathToFileURL(join(runtime, 'node_modules/@hyperframes/producer/dist/index.js')).href);
  const compiled = core.compileTimingAttrs(html).html;
  const lint = await producer.runHyperframeLint({entryFile: 'index.html', html: compiled});
  assert.equal(lint.errorCount, 0, lint.findings.map((finding) => finding.message).join('\n'));
  return {audio: engine.parseAudioElements(compiled), compiled, videos: engine.parseVideoElements(compiled)};
}

async function generatedProject(snapshot, fixtureId) {
  const project = await mkdtemp(join(tmpdir(), `takeform-hf-${fixtureId.toLowerCase()}-`));
  await writeTlProject(snapshot, fixtureId, fixtureRoot, project, new Map(), project);
  return {html: await readFile(join(project, 'index.html'), 'utf8'), project};
}

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

test('future receipts distinguish semantic manifest and raw file fingerprints', () => {
  const manifestBytes = Buffer.from('{"manifestDigest":"semantic","entries":[]}\n');
  const receipt = mediaPreparationReceipt(manifestBytes, {manifestDigest: 'semantic'}, [{sourceId: 'still', prepared: {sha256: 'derived'}}]);
  assert.equal(receipt.semanticManifestDigest, 'semantic');
  assert.notEqual(receipt.rawManifestSha256, receipt.semanticManifestDigest);
  assert.deepEqual(receipt.derivativeHashes, [{sourceId: 'still', sha256: 'derived'}]);
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

test('T generates a producer-compiled composition with separate retimed audio and corrected caption edges', async () => {
  assert.ok(fixtureRoot);
  const snapshot = await freezeSnapshot({acceptedCommit, fixtureRoot});
  const payload = tlPayload(snapshot, 'T');
  assert.equal(payload.frameCount, 2700);
  assert.deepEqual(payload.rate, {num: 30, den: 1});
  assert.equal(payload.captions.at(-1).endFrame <= payload.frameCount, true);
  const secondTake = payload.visuals.find((visual) => visual.sourceId === 'take2');
  assert.ok(secondTake);
  assert.notDeepEqual(secondTake.sourceRate, {num: 1, den: 1});
  const {html, project} = await generatedProject(snapshot, 'T');
  try {
    const parsed = await pinnedPublicParsers(html);
    assert.equal(parsed.videos.length, payload.visuals.length);
    assert.equal(parsed.audio.length, payload.tracks.length);
    assert.ok(parsed.videos.every((video) => video.hasAudio === false));
    assert.ok(parsed.audio.some((track) => track.id.includes('oDlg2A') && track.playbackRate !== 1));
    assert.ok(parsed.audio.some((track) => track.fxChain && track.automation));
    assert.ok(html.includes('creator names the cut,'), 'corrected caption text must be emitted');
    assert.deepEqual((await readdir(join(project, 'media'))).sort(), Object.values(payload.sources).map((source) => source.path.slice('media/'.length)).sort());
  } finally {
    await rm(project, {force: true, recursive: true});
  }
});

test('L generates exact rational-rate joins, dual visual handles, and continuous separate audio', async () => {
  assert.ok(fixtureRoot);
  const snapshot = await freezeSnapshot({acceptedCommit, fixtureRoot});
  const payload = tlPayload(snapshot, 'L');
  assert.equal(payload.frameCount, 43157);
  assert.deepEqual(payload.rate, {num: 24000, den: 1001});
  assert.equal(payload.chapters.length, 15);
  const transitionVisuals = payload.visuals.filter((visual) => visual.styleSamples.length > 1);
  assert.equal(transitionVisuals.length, 28);
  const {html, project} = await generatedProject(snapshot, 'L');
  try {
    const parsed = await pinnedPublicParsers(html);
    assert.equal(parsed.videos.length, payload.visuals.length);
    assert.equal(parsed.audio.length, payload.tracks.length);
    assert.ok(parsed.videos.every((video) => video.hasAudio === false));
    assert.ok(parsed.audio.every((track) => track.start >= 0 && track.end > track.start));
    assert.ok(html.includes('chapter15'));
    assert.match(html, /data-composition-id="takeform-L"[^>]*data-duration="/);
  } finally {
    await rm(project, {force: true, recursive: true});
  }
});
