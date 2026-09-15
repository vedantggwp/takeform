import { createHash } from 'node:crypto';
import { link, mkdir, readFile, realpath, rm, stat, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';

export class MasteringError extends Error {
  constructor(message, code, receipt) { super(message); this.name = 'MasteringError'; this.code = code; this.receipt = receipt; }
}

const ABS = value => typeof value === 'string' && path.isAbsolute(value);
const sha256 = async file => createHash('sha256').update(await readFile(file)).digest('hex');
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const finite = value => Number.isFinite(Number(value));
const round = (value, resolution) => Math.round(Number(value) / resolution) * resolution;

function assert(condition, message, code, receipt) { if (!condition) throw new MasteringError(message, code, receipt); }

async function command(binary, args, { signal, stage } = {}) {
  return await new Promise((resolve, reject) => {
    const startedAt = new Date().toISOString();
    const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', cancelled = false, peakRssBytes = 0, samplerError = null;
    const samples = [];
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    const abort = () => { cancelled = true; child.kill('SIGTERM'); };
    if (signal?.aborted) abort();
    signal?.addEventListener('abort', abort, { once: true });
    const sampleRss = () => {
      const ps = spawn('/bin/ps', ['-o', 'rss=,time=', '-p', String(child.pid)], { stdio: ['ignore', 'pipe', 'ignore'] });
      let value = '';
      ps.stdout.on('data', chunk => { value += chunk; });
      ps.on('error', error => { samplerError ??= error.message; });
      ps.on('close', code => {
        if (code !== 0) { samplerError ??= `ps exit ${code}`; return; }
        const [rssKiB, cpu] = value.trim().split(/\s+/);
        if (!/^\d+$/.test(rssKiB ?? '')) { samplerError ??= 'ps returned no RSS'; return; }
        peakRssBytes = Math.max(peakRssBytes, Number(rssKiB) * 1024);
        samples.push({ at: new Date().toISOString(), rssBytes: Number(rssKiB) * 1024, cpu });
      });
    };
    sampleRss(); const sampler = setInterval(sampleRss, 100);
    child.on('error', error => reject(error));
    child.on('close', (exitCode, signalName) => {
      clearInterval(sampler);
      signal?.removeEventListener('abort', abort);
      resolve({ stage, binary, args, startedAt, endedAt: new Date().toISOString(), elapsedMs: Date.now() - Date.parse(startedAt), stdout, stderr, exitCode, signal: signalName, cancelled, child: { pid: child.pid, reaped: true, peakRssBytes, samples, samplerError } });
    });
  });
}

async function probe(ffprobePath, file) {
  const result = await command(ffprobePath, ['-v', 'error', '-show_streams', '-show_format', '-show_data', '-of', 'json', file], { stage: 'probe' });
  assert(result.exitCode === 0, 'ffprobe could not read raw artifact', 'unreadable-input', { command: result });
  const data = JSON.parse(result.stdout);
  const video = data.streams.find(stream => stream.codec_type === 'video');
  const audio = data.streams.find(stream => stream.codec_type === 'audio');
  assert(video, 'raw artifact has no video stream', 'streamless-video', { probe: data });
  assert(audio, 'raw artifact has no audio stream', 'streamless-audio', { probe: data });
  return { data, video, audio, command: result };
}

function mediaIdentity(stream) {
  return { codec: stream.codec_name, codecTag: stream.codec_tag_string, profile: stream.profile ?? null, width: stream.width, height: stream.height, timeBase: stream.time_base, extradataSha256: createHash('sha256').update(stream.extradata ?? '').digest('hex') };
}

function loudnormJson(stderr) {
  const matches = stderr.match(/\{\s*"input_i"[\s\S]*?\}/g) ?? [];
  const raw = matches.at(-1);
  if (!raw) throw new MasteringError('loudnorm did not emit EBU R128 JSON', 'measurement-missing');
  const value = JSON.parse(raw);
  for (const key of ['input_i', 'input_tp', 'input_lra', 'input_thresh', 'target_offset']) assert(finite(value[key]), `loudnorm emitted non-finite ${key}`, 'nonfinite-audio');
  return { integratedLufs: Number(value.input_i), truePeakDbtp: Number(value.input_tp), lra: Number(value.input_lra), threshold: Number(value.input_thresh), offset: Number(value.target_offset), raw: value };
}

async function measure(ffmpegPath, file, policy, signal, stage) {
  const filter = `loudnorm=I=${policy.targetIntegratedLufs}:LRA=${policy.loudnessRangeTarget}:TP=${policy.maxTruePeakDbtp}:print_format=json`;
  const result = await command(ffmpegPath, ['-hide_banner', '-nostats', '-i', file, '-map', '0:a:0', '-af', filter, '-f', 'null', '-'], { signal, stage });
  assert(!result.cancelled && result.exitCode === 0, `${stage} EBU R128 analysis failed`, result.cancelled ? 'cancelled' : 'measurement-failed', { command: result });
  return { ...loudnormJson(result.stderr), command: result, filter };
}

async function audioHealth(ffmpegPath, file, signal) {
  const result = await command(ffmpegPath, ['-hide_banner', '-nostats', '-i', file, '-map', '0:a:0', '-af', 'astats=metadata=0:reset=0', '-f', 'null', '-'], { signal, stage: 'audio-health' });
  assert(!result.cancelled && result.exitCode === 0, 'audio health scan failed', result.cancelled ? 'cancelled' : 'unreadable-input', { command: result });
  const max = Number((result.stderr.match(/Max level:\s*([^\s]+)/g) ?? []).at(-1)?.split(/\s+/).at(-1));
  const nonfinite = /Number of (?:NaNs|Infs):\s*[1-9]/.test(result.stderr);
  assert(finite(max) && !nonfinite, 'raw audio contains non-finite samples', 'nonfinite-audio', { command: result });
  assert(max > 0, 'raw audio is silent', 'silent-audio', { command: result });
  return { maxLevel: max, command: result };
}

async function decodedFrameHash(ffmpegPath, file, frame) {
  const result = await command(ffmpegPath, ['-hide_banner', '-v', 'error', '-i', file, '-vf', `select=eq(n\\,${frame})`, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-'], { stage: `video-sample-${frame}` });
  assert(result.exitCode === 0 && result.stdout.length > 0, `cannot decode video sample ${frame}`, 'video-sample-failed', { command: result });
  return createHash('sha256').update(result.stdout).digest('hex');
}

export function timingFromStreams(audio, video) {
  const required = (value, label) => {
    assert(finite(value), `${label} metadata is unavailable or non-finite`, 'timing-unavailable');
    return Number(value);
  };
  const audioStartSeconds = required(audio.start_time, 'audio start time');
  const videoStartSeconds = required(video.start_time, 'video start time');
  return { channels: required(audio.channels, 'audio channels'), sampleRate: required(audio.sample_rate, 'audio sample rate'), durationSeconds: required(audio.duration, 'audio duration'), audioStartSeconds, videoStartSeconds, avStartOffsetSeconds: audioStartSeconds - videoStartSeconds };
}

function primingBound(policy, sampleRate) {
  assert(Number.isSafeInteger(policy.primingAccessUnits) && policy.primingAccessUnits >= 0, 'policy must declare non-negative AAC priming access units', 'invalid-policy');
  assert(policy.audioCodec === 'aac', 'only explicit AAC priming policy is currently supported', 'invalid-policy');
  return policy.primingAccessUnits * 1024 / sampleRate;
}

async function publishNoReplace(tempOutput, outputPath, signal) {
  assert(!signal?.aborted, 'mastering cancelled before publication', 'cancelled');
  try { await link(tempOutput, outputPath); }
  catch (error) {
    if (error.code === 'EEXIST') throw new MasteringError('refusing to overwrite concurrently-created mastered output', 'output-exists');
    if (error.code === 'EXDEV') throw new MasteringError('atomic no-replace publish requires output on the attempt filesystem', 'cross-device-publish');
    throw error;
  }
  await unlink(tempOutput);
}

export async function masterArtifact({ rawPath, outputPath, attemptRoot, binaries, policy, videoSampleFrames, signal, hooks } = {}) {
  assert(ABS(rawPath) && ABS(outputPath) && ABS(attemptRoot), 'rawPath, outputPath, and attemptRoot must be absolute paths', 'invalid-path');
  assert(binaries?.ffmpegPath && binaries?.ffprobePath && ABS(binaries.ffmpegPath) && ABS(binaries.ffprobePath), 'explicit absolute ffmpegPath and ffprobePath are required', 'invalid-binaries');
  assert(policy && finite(policy.targetIntegratedLufs) && finite(policy.maxTruePeakDbtp) && finite(policy.loudnessRangeTarget) && finite(policy.measurementResolution), 'declared mastering policy is incomplete', 'invalid-policy');
  assert(Array.isArray(videoSampleFrames) && videoSampleFrames.length >= 4 && videoSampleFrames.every(item => Number.isSafeInteger(item) && item >= 0), 'four declared video sample frames are required', 'invalid-video-samples');
  const started = Date.now(); const receipt = { schemaVersion: 1, status: 'started', rawPath, outputPath, policy, commands: [] };
  const tempDir = path.join(attemptRoot, 'tmp'); const tempOutput = path.join(tempDir, 'master.partial.mp4');
  try {
    await mkdir(tempDir, { recursive: true });
    assert(!(await stat(outputPath).then(() => true).catch(() => false)), 'refusing to overwrite existing mastered output', 'output-exists');
    assert(await stat(rawPath).then(item => item.isFile()).catch(() => false), 'raw artifact is missing', 'missing-input');
    const rawReal = await realpath(rawPath); receipt.raw = { sha256: await sha256(rawReal), bytes: (await stat(rawReal)).size };
    const version = await command(binaries.ffmpegPath, ['-version'], { stage: 'ffmpeg-version' }); receipt.commands.push(version);
    assert(version.exitCode === 0, 'ffmpeg version check failed', 'invalid-binaries', receipt);
    receipt.ffmpeg = { path: binaries.ffmpegPath, version: version.stdout.split('\n')[0] };
    const rawProbe = await probe(binaries.ffprobePath, rawReal); receipt.commands.push(rawProbe.command); receipt.raw.streams = rawProbe.data.streams;
    receipt.raw.videoIdentity = mediaIdentity(rawProbe.video); receipt.raw.timing = timingFromStreams(rawProbe.audio, rawProbe.video);
    const health = await audioHealth(binaries.ffmpegPath, rawReal, signal); receipt.commands.push(health.command); receipt.raw.health = { maxLevel: health.maxLevel };
    const before = await measure(binaries.ffmpegPath, rawReal, policy, signal, 'measure-raw'); receipt.commands.push(before.command); receipt.raw.measurement = before;
    // atrim limits only the normalized audio; a global -t would truncate a longer copied video when audio starts later.
    const filter = `loudnorm=I=${policy.targetIntegratedLufs}:LRA=${policy.loudnessRangeTarget}:TP=${policy.maxTruePeakDbtp}:measured_I=${before.integratedLufs}:measured_LRA=${before.lra}:measured_TP=${before.truePeakDbtp}:measured_thresh=${before.threshold}:offset=${before.offset}:linear=false:print_format=json,atrim=duration=${receipt.raw.timing.durationSeconds}`;
    const argv = ['-hide_banner', '-y', '-i', rawReal, '-map', '0:v:0', '-map', '0:a:0', '-c:v', 'copy', '-c:a', policy.audioCodec, '-b:a', policy.audioBitrate, '-ac', String(rawProbe.audio.channels), '-ar', String(receipt.raw.timing.sampleRate), '-af', filter, '-movflags', '+faststart', tempOutput];
    receipt.transform = { argv, settingsDigest: digest({ binary: binaries.ffmpegPath, argv, policy }) };
    const transformed = await command(binaries.ffmpegPath, argv, { signal, stage: 'master' }); receipt.commands.push(transformed);
    assert(!transformed.cancelled && transformed.exitCode === 0, 'mastering transform failed', transformed.cancelled ? 'cancelled' : 'transform-failed', receipt);
    const masteredProbe = await probe(binaries.ffprobePath, tempOutput); receipt.commands.push(masteredProbe.command); receipt.mastered = { streams: masteredProbe.data.streams, videoIdentity: mediaIdentity(masteredProbe.video), timing: timingFromStreams(masteredProbe.audio, masteredProbe.video) };
    assert(JSON.stringify(receipt.mastered.videoIdentity) === JSON.stringify(receipt.raw.videoIdentity), 'video stream-copy identity changed', 'video-not-preserved', receipt);
    for (const frame of videoSampleFrames) {
      const [rawHash, masteredHash] = await Promise.all([decodedFrameHash(binaries.ffmpegPath, rawReal, frame), decodedFrameHash(binaries.ffmpegPath, tempOutput, frame)]);
      assert(rawHash === masteredHash, `decoded video differs at frame ${frame}`, 'video-not-preserved', receipt);
      (receipt.videoSamples ??= []).push({ frame, sha256: rawHash });
    }
    const after = await measure(binaries.ffmpegPath, tempOutput, policy, signal, 'measure-mastered'); receipt.commands.push(after.command); receipt.mastered.measurement = after;
    assert(round(after.integratedLufs, policy.measurementResolution) === round(policy.targetIntegratedLufs, policy.measurementResolution), 'mastered integrated loudness misses declared target at declared resolution', 'target-missed', receipt);
    assert(after.truePeakDbtp <= policy.maxTruePeakDbtp, 'mastered true peak exceeds declared ceiling', 'peak-exceeded', receipt);
    const rawTiming = receipt.raw.timing, masteredTiming = receipt.mastered.timing;
    assert(rawTiming.channels === masteredTiming.channels && rawTiming.sampleRate === masteredTiming.sampleRate, 'mastered audio layout changed', 'audio-layout-changed', receipt);
    const primingBoundSeconds = primingBound(policy, rawTiming.sampleRate);
    receipt.priming = { durationDifferenceSeconds: masteredTiming.durationSeconds - rawTiming.durationSeconds, avOffsetDifferenceSeconds: masteredTiming.avStartOffsetSeconds - rawTiming.avStartOffsetSeconds, allowedAacAccessUnits: policy.primingAccessUnits, boundSeconds: primingBoundSeconds };
    assert(Math.abs(receipt.priming.durationDifferenceSeconds) <= primingBoundSeconds && Math.abs(receipt.priming.avOffsetDifferenceSeconds) <= primingBoundSeconds, 'encoder priming/edit-list difference exceeds AAC-derived duration or start-offset bound', 'timing-out-of-bounds', receipt);
    await hooks?.beforePublish?.(receipt);
    await publishNoReplace(tempOutput, outputPath, signal); receipt.mastered.sha256 = await sha256(outputPath); receipt.status = 'succeeded'; receipt.elapsedMs = Date.now() - started;
    return receipt;
  } catch (error) {
    receipt.status = error.code === 'cancelled' ? 'cancelled' : 'failed'; receipt.error = { code: error.code ?? 'unexpected', message: error.message }; receipt.elapsedMs = Date.now() - started;
    throw new MasteringError(error.message, error.code ?? 'unexpected', receipt);
  } finally {
    await rm(tempOutput, { force: true });
    receipt.cost = { peakChildRssBytes: Math.max(0, ...receipt.commands.map(item => item.child?.peakRssBytes ?? 0)), sampledChildren: receipt.commands.map(item => item.child).filter(Boolean), producerBytes: receipt.raw?.bytes ?? null, masteredBytes: receipt.mastered?.sha256 ? (await stat(outputPath)).size : null };
    receipt.cleanup = { partialOutputAbsent: !(await stat(tempOutput).then(() => true).catch(() => false)) };
    await mkdir(attemptRoot, { recursive: true });
    await writeFile(path.join(attemptRoot, 'terminal-receipt.json'), JSON.stringify(receipt, null, 2));
  }
}
