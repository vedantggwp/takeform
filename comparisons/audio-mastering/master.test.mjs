import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, mkdir, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { masterArtifact, MasteringError } from './master.mjs';

const ffmpegPath = '/opt/homebrew/bin/ffmpeg';
const ffprobePath = '/opt/homebrew/bin/ffprobe';
const policy = { targetIntegratedLufs: -16, maxTruePeakDbtp: -1, loudnessRangeTarget: 11, measurementResolution: 0.1, maxPrimingOffsetSeconds: 0.15, audioCodec: 'aac', audioBitrate: '192k' };
const run = (args) => new Promise((resolve, reject) => execFile(ffmpegPath, args, { maxBuffer: 1024 * 1024 }, error => error ? reject(error) : resolve()));
const exists = async file => stat(file).then(() => true).catch(() => false);

async function media(root, { audio = 'sine=frequency=440:sample_rate=48000' } = {}) {
  const output = path.join(root, 'raw.mp4');
  const args = ['-hide_banner', '-y', '-f', 'lavfi', '-i', 'color=c=navy:s=160x90:r=30:d=3'];
  if (audio) args.push('-f', 'lavfi', '-i', audio);
  args.push('-t', '3', '-map', '0:v:0'); if (audio) args.push('-map', '1:a:0');
  args.push('-c:v', 'libx264', '-pix_fmt', 'yuv420p'); if (audio) args.push('-c:a', 'aac'); args.push(output);
  await run(args); return output;
}

async function setup() { const root = await mkdtemp(path.join(os.tmpdir(), 'takeform-audio-master-')); await mkdir(path.join(root, 'attempt')); return { root, attemptRoot: path.join(root, 'attempt'), outputPath: path.join(root, 'mastered.mp4') }; }
const options = ({ rawPath, outputPath, attemptRoot, signal }) => ({ rawPath, outputPath, attemptRoot, signal, binaries: { ffmpegPath, ffprobePath }, policy, videoSampleFrames: [0, 30, 60, 89] });

test('masters real media transactionally and preserves decoded video', async () => {
  const ctx = await setup(); const rawPath = await media(ctx.root);
  const receipt = await masterArtifact(options({ ...ctx, rawPath }));
  assert.equal(receipt.status, 'succeeded'); assert.equal(await exists(ctx.outputPath), true);
  assert.equal(receipt.videoSamples.length, 4); assert.equal(Math.round(receipt.mastered.measurement.integratedLufs * 10), -160);
});

test('rejects absent, silent, and existing output before publication', async () => {
  const absent = await setup(); await assert.rejects(() => masterArtifact(options({ ...absent, rawPath: path.join(absent.root, 'missing.mp4') })), error => error instanceof MasteringError && error.code === 'missing-input');
  const streamless = await setup(); const videoOnly = await media(streamless.root, { audio: null }); await assert.rejects(() => masterArtifact(options({ ...streamless, rawPath: videoOnly })), error => error.code === 'streamless-audio');
  const silent = await setup(); const silentRaw = await media(silent.root, { audio: 'anullsrc=r=48000:cl=stereo' }); await assert.rejects(() => masterArtifact(options({ ...silent, rawPath: silentRaw })), error => error.code === 'silent-audio');
  const overwrite = await setup(); const rawPath = await media(overwrite.root); await run(['-hide_banner', '-y', '-f', 'lavfi', '-i', 'color=s=16x16:d=0.1', '-frames:v', '1', overwrite.outputPath]); await assert.rejects(() => masterArtifact(options({ ...overwrite, rawPath })), error => error.code === 'output-exists');
});

test('cancellation leaves no partial or publishable output and writes a terminal receipt', async () => {
  const ctx = await setup(); const rawPath = await media(ctx.root); const controller = new AbortController(); controller.abort();
  await assert.rejects(() => masterArtifact(options({ ...ctx, rawPath, signal: controller.signal })), error => error.code === 'cancelled');
  assert.equal(await exists(ctx.outputPath), false); assert.equal(await exists(path.join(ctx.attemptRoot, 'tmp', 'master.partial.mp4')), false); assert.equal(await exists(path.join(ctx.attemptRoot, 'terminal-receipt.json')), true);
});
