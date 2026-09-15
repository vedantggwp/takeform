import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp, lstat, readFile, rm, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {compositionModule, validateRequest, writeProject} from './episode-render-worker.mjs';

const rational = (value, timescale = 1) => ({value, timescale});
const range = (start, duration) => ({start: rational(start), duration: rational(duration)});
const rect = (x, y, width, height) => ({x: rational(x, 4), y: rational(y, 4), width: rational(width, 4), height: rational(height, 4)});
const occurrence = (id, assetID, digest, source, outputRange, outputRect, layer, order) => ({id, assetID, assetDigest: digest, source, outputRange, outputRect, layer, order, crop: rect(0, 0, 4, 4)});
const request = () => ({schemaVersion: 1, jobID: 'job', attemptID: 'attempt', stageDirectory: '/private/tmp/stage', outputFileName: 'episode.mp4', runtime: {runtimeRoot: '/private/tmp/runtime'}, resolvedObjects: [{assetID: 'still', digest: 'a'.repeat(64), localPath: '/private/tmp/still.png'}, {assetID: 'video', digest: 'b'.repeat(64), localPath: '/private/tmp/clip.mp4'}], snapshot: {projectID: 'project', episodeID: 'episode', requestedRevision: 3, compositionDigest: 'c'.repeat(64), assets: [{id: 'still', digest: 'a'.repeat(64)}, {id: 'video', digest: 'b'.repeat(64)}], composition: {clipAudioPolicy: 'muted', output: {width: 1920, height: 1080, frameRate: rational(30), duration: rational(4)}, occurrences: [occurrence('left', 'still', 'a'.repeat(64), {type: 'still'}, range(0, 4), rect(0, 1, 2, 2), 0, 0), occurrence('right', 'video', 'b'.repeat(64), {type: 'video', range: range(2, 2)}, range(1, 2), rect(2, 1, 2, 2), 1, 1)], captions: [{id: 'caption', text: 'Ready', outputRange: range(1, 1), layer: 0, order: 0}]}}});

test('worker binds each occurrence to its immutable resolved object', () => {
  assert.equal(validateRequest(request()).size, 2);
  const invalid = request(); invalid.resolvedObjects[1].digest = '0'.repeat(64);
  assert.throws(() => validateRequest(invalid), {code: 'OBJECT_BINDING_MISMATCH'});
});

test('worker accepts canonical Swift enum source encodings', () => {
  const value = request();
  value.snapshot.composition.occurrences[0].source = {still: {}};
  value.snapshot.composition.occurrences[1].source = {video: {_0: range(2, 2)}};
  assert.equal(validateRequest(value).size, 2);
  assert.match(compositionModule(value.snapshot.composition, {left: 'media/left.png', right: 'media/right.mp4'}), /source\.video\.range\?\?source\.video\._0/);
});

test('generated composition uses one element per occurrence and top-left output rectangles', () => {
  const value = request();
  const source = compositionModule(value.snapshot.composition, {left: 'media/left.png', right: 'media/right.mp4'});
  assert.match(source, /nodes\.set\(occurrence\.id,node\)/);
  assert.match(source, /node\.style\.top=\(seconds\(occurrence\.outputRect\.y\)\*100\)/);
  assert.match(source, /node\.style\.left=\(seconds\(occurrence\.outputRect\.x\)\*100\)/);
  assert.match(source, /videoTime\(occurrence,time\)/);
  assert.match(source, /node\.muted=true/);
});

test('worker stages distinct occurrence links without mutating source media', async () => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-episode-worker-'));
  try {
    const still = join(root, 'still.png');
    const video = join(root, 'clip.mp4');
    await writeFile(still, 'still-source');
    await writeFile(video, 'video-source');
    const value = request();
    value.stageDirectory = join(root, 'stage');
    value.resolvedObjects[0].localPath = still;
    value.resolvedObjects[1].localPath = video;
    const project = await writeProject(value);
    assert.equal((await lstat(join(project.project, 'media', 'left.png'))).isSymbolicLink(), true);
    assert.equal((await lstat(join(project.project, 'media', 'right.mp4'))).isSymbolicLink(), true);
    assert.match(await readFile(join(project.project, 'composition.mjs'), 'utf8'), /media\/left\.png/);
    assert.equal(await readFile(still, 'utf8'), 'still-source');
    assert.equal(await readFile(video, 'utf8'), 'video-source');
  } finally {
    await rm(root, {force: true, recursive: true});
  }
});
