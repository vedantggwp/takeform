import assert from 'node:assert/strict';
import test from 'node:test';
import {chmod, copyFile, mkdtemp, lstat, readFile, rm, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {compositionModule, runAttempt, runtimeProfile, validateRequest, validateRuntime, writeProject} from './episode-render-worker.mjs';

const rational = (value, timescale = 1) => ({value, timescale});
const range = (start, duration) => ({start: rational(start), duration: rational(duration)});
const rect = (x, y, width, height) => ({x: rational(x, 4), y: rational(y, 4), width: rational(width, 4), height: rational(height, 4)});
const occurrence = (id, assetID, digest, source, outputRange, outputRect, layer, order) => ({id, assetID, assetDigest: digest, source, outputRange, outputRect, layer, order, crop: rect(0, 0, 4, 4)});
const request = () => ({schemaVersion: 1, jobID: 'job', attemptID: 'attempt', snapshotSHA256: 'd'.repeat(64), stageDirectory: '/private/tmp/stage', outputFileName: 'episode.mp4', runtime: {runtimeRoot: '/private/tmp/runtime'}, resolvedObjects: [{assetID: 'still', digest: 'a'.repeat(64), byteLength: 12, localPath: '/private/tmp/still.png'}, {assetID: 'video', digest: 'b'.repeat(64), byteLength: 34, localPath: '/private/tmp/clip.mp4'}], snapshot: {projectID: 'project', episodeID: 'episode', requestedRevision: 3, compositionDigest: 'c'.repeat(64), format: 'mp4', assets: [{id: 'still', digest: 'a'.repeat(64), byteLength: 12}, {id: 'video', digest: 'b'.repeat(64), byteLength: 34}], composition: {clipAudioPolicy: 'muted', output: {width: 1920, height: 1080, frameRate: rational(30), duration: rational(4)}, occurrences: [occurrence('left', 'still', 'a'.repeat(64), {type: 'still'}, range(0, 4), rect(0, 1, 2, 2), 0, 0), occurrence('right', 'video', 'b'.repeat(64), {type: 'video', range: range(2, 2)}, range(1, 2), rect(2, 1, 2, 2), 1, 1)], captions: [{id: 'caption', text: 'Ready', outputRange: range(1, 1), layer: 0, order: 0}]}}});

test('worker binds each occurrence to its immutable resolved object', () => {
  assert.equal(validateRequest(request()).size, 2);
  const invalid = request(); invalid.resolvedObjects[1].digest = '0'.repeat(64);
  assert.throws(() => validateRequest(invalid), {code: 'OBJECT_BINDING_MISMATCH'});
});

test('worker requires the authority-provided canonical snapshot hash', () => {
  const value = request();
  value.snapshotSHA256 = 'not-a-digest';
  assert.throws(() => validateRequest(value), {code: 'INVALID_REQUEST'});
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

test('runtime rejects a forged pinned package identity before a renderer import', async () => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-runtime-profile-'));
  try {
    const browser = join(root, 'browser');
    const browserWrapper = join(root, 'tools', 'secure-browser-launcher.sh');
    const ffmpeg = join(root, 'ffmpeg');
    const ffprobe = join(root, 'ffprobe');
    await Promise.all([browser, ffmpeg, ffprobe].map(async (path) => {
      await writeFile(path, '#!/bin/sh\nexit 0\n');
      await chmod(path, 0o755);
    }));
    await import('node:fs/promises').then(({mkdir}) => mkdir(join(root, 'tools'), {recursive: true}));
    await copyFile(new URL('./launchers/secure-browser-launcher.sh', import.meta.url), browserWrapper);
    await chmod(browserWrapper, 0o755);
    await Promise.all(runtimeProfile.packages.map(async ({path, name, version}) => {
      const packagePath = join(root, 'node_modules', path, 'package.json');
      await writeFile(packagePath, JSON.stringify({name, version}), {flag: 'w'}).catch(async (error) => {
        if (error.code !== 'ENOENT') throw error;
        const {mkdir} = await import('node:fs/promises');
        await mkdir(join(root, 'node_modules', path), {recursive: true});
        await writeFile(packagePath, JSON.stringify({name, version}));
      });
    }));
    const runtime = {runtimeRoot: root, nodeVersion: runtimeProfile.nodeVersion, browserTargetExecutable: browser, ffmpegExecutable: ffmpeg, ffprobeExecutable: ffprobe};
    assert.equal((await validateRuntime(runtime)).packages.length, 5);
    await writeFile(join(root, 'node_modules/@hyperframes/engine/package.json'), JSON.stringify({name: '@hyperframes/not-engine', version: '0.8.39'}));
    await assert.rejects(validateRuntime(runtime), {code: 'RUNTIME_PACKAGE_MISMATCH'});
  } finally {
    await rm(root, {force: true, recursive: true});
  }
});

test('runtime rejects a modified packaged browser wrapper before renderer import', async () => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-runtime-launcher-'));
  try {
    const browser = join(root, 'browser');
    const ffmpeg = join(root, 'ffmpeg');
    const ffprobe = join(root, 'ffprobe');
    await Promise.all([browser, ffmpeg, ffprobe].map(async (path) => {
      await writeFile(path, '#!/bin/sh\nexit 0\n');
      await chmod(path, 0o755);
    }));
    const {mkdir} = await import('node:fs/promises');
    await mkdir(join(root, 'tools'), {recursive: true});
    const wrapper = join(root, 'tools', 'secure-browser-launcher.sh');
    await copyFile(new URL('./launchers/secure-browser-launcher.sh', import.meta.url), wrapper);
    await chmod(wrapper, 0o755);
    for (const {path, name, version} of runtimeProfile.packages) {
      const packageDirectory = join(root, 'node_modules', path);
      await mkdir(packageDirectory, {recursive: true});
      await writeFile(join(packageDirectory, 'package.json'), JSON.stringify({name, version}));
    }
    await writeFile(wrapper, '#!/bin/sh\nexit 0\n');
    await assert.rejects(validateRuntime({runtimeRoot: root, nodeVersion: runtimeProfile.nodeVersion, browserTargetExecutable: browser, ffmpegExecutable: ffmpeg, ffprobeExecutable: ffprobe}), {code: 'RUNTIME_LAUNCHER_MISMATCH'});
  } finally {
    await rm(root, {force: true, recursive: true});
  }
});

test('runtime preflight failure writes a failed receipt before project staging or SDK import', async () => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-worker-preflight-'));
  try {
    const value = request();
    value.stageDirectory = root;
    value.runtime = {runtimeRoot: root, nodeVersion: runtimeProfile.nodeVersion, browserTargetExecutable: join(root, 'browser'), ffmpegExecutable: join(root, 'ffmpeg'), ffprobeExecutable: join(root, 'ffprobe')};
    await assert.rejects(runAttempt(value), {code: 'RUNTIME_PACKAGE_UNAVAILABLE'});
    const receipt = JSON.parse(await readFile(join(root, 'attempt-receipt.json'), 'utf8'));
    assert.equal(receipt.outcome, 'failed');
    assert.equal(receipt.error.code, 'RUNTIME_PACKAGE_UNAVAILABLE');
    await assert.rejects(lstat(join(root, 'project')), {code: 'ENOENT'});
  } finally {
    await rm(root, {force: true, recursive: true});
  }
});
