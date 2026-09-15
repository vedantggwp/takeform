import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import os from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {buildMPlayerBundle} from './player.mjs';

const fixtureRoot = process.env.TAKEFORM_FIXTURE_ROOT;
const runtime = process.env.TAKEFORM_RUNTIME;
const derivativeRoot = process.env.TAKEFORM_DERIVATIVE_ROOT;
const mediaPrepManifestPath = process.env.TAKEFORM_MEDIA_PREP_MANIFEST;
const mediaPrepModulePath = process.env.TAKEFORM_MEDIA_PREP_MODULE;
const configured = [fixtureRoot, runtime, derivativeRoot, mediaPrepManifestPath, mediaPrepModulePath].every(Boolean);

test('M Player bundle uses pinned local runtime, frameState media, and the approved derivatives', {skip: !configured}, async t => {
  const root = await mkdtemp(join(os.tmpdir(), 'takeform-hyperframes-player-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const receipt = await buildMPlayerBundle({bundleRoot: root, derivativeRoot, fixtureRoot, mediaPrepManifestPath, mediaPrepModulePath, runtime});
  assert.equal(receipt.snapshotId, '9e43cabfe12f8241fe77187624b94dafdf9bce455842f35201b0a1a1f29e919c');
  assert.deepEqual(receipt.rate, {num: 30, den: 1});
  assert.equal(receipt.frameCount, 480);
  const station = receipt.sourceAssets.find(asset => asset.sourceId === 'station');
  assert.equal(station.bundlePath, 'media/station.png');
  assert.equal(station.preparedSha256, 'b7b06cbf3075abc4f5b6a464235dd60ed3c91244599d9982ce9c92bc5ce1853d');
  const clip24 = receipt.sourceAssets.find(asset => asset.sourceId === 'clip24');
  assert.deepEqual({sourceExtension: clip24.sourceExtension, servedExtension: clip24.servedExtension}, {sourceExtension: '.mov', servedExtension: '.mov'});
  const [index, composition, verification, notices, license] = await Promise.all([
    readFile(join(root, 'index.html'), 'utf8'), readFile(join(root, 'composition.html'), 'utf8'), readFile(join(root, 'verification.json'), 'utf8'),
    readFile(join(root, 'THIRD_PARTY_NOTICES.md'), 'utf8'), readFile(join(root, 'LICENSES/Apache-2.0-HeyGen.txt'), 'utf8')
  ]);
  assert.match(index, /<hyperframes-player/);
  assert.doesNotMatch(index, /window\.__|__timelines|gsap/i);
  assert.match(composition, /data-composition-id="takeform-montage"/);
  assert.match(composition, /data-media-start="0"/);
  assert.match(composition, /data-takeform-occurrence-id="oClip24"[^>]*><\/video>/);
  assert.match(composition, /data-takeform-occurrence-id="oClip2997"[^>]*><\/video>/);
  const state = JSON.parse(verification);
  assert.deepEqual(state.frames[180].media, [{occurrenceId: 'oClip24', sourceId: 'clip24', sourceTimeSeconds: 1}]);
  assert.deepEqual(state.frames[300].media, [{occurrenceId: 'oClip2997', sourceId: 'clip2997', sourceTimeSeconds: 1}]);
  assert.deepEqual(state.frames[300].pictures.map(picture => picture.occurrenceId), ['oMarket', 'oLibrary', 'oClip2997']);
  assert.equal(state.frames[300].pictures.find(picture => picture.occurrenceId === 'oClip2997').opacity, 1);
  assert.ok(state.occurrenceIds.includes('oClip2997'));
  assert.match(index, /requested frame was not painted/);
  assert.match(index, /inactiveLayerHidden/);
  assert.match(index, /window\.takeformPreviewCommand/);
  assert.match(index, /return respond\(command,'painted'\)/);
  assert.match(notices, /@hyperframes\/player.*0\.8\.39/s);
  assert.match(notices, /@hyperframes\/core.*0\.8\.39/s);
  assert.match(notices, /d13a89b6707203a2efe2cfcd4e996e0ad0aa4573/);
  assert.match(notices, /c47ac3a56fb41be0423a17f000dc7ec6cec60814942ad4c49086bffd4fe20883/);
  assert.match(notices, /ef6bc0878ca69592c3fd911325f9452eb8e483d98255caaaae2e7b79b8df6cbc/);
  assert.match(license, /Apache License/);
  assert.match(license, /Copyright 2026 HeyGen, Inc\./);
});
