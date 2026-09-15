import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {appendFile, mkdir, readdir, readFile, stat, statfs, symlink, writeFile} from 'node:fs/promises';
import {basename, extname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {promisify} from 'node:util';
import {cleanupAttemptScratch, createAttempt, finishAttempt, freezeSnapshot, frameState, reserveStorage} from '../common/index.mjs';
import {writeTlProject} from './tl-composition.mjs';

const acceptedCommit = '8a3daf1978093a3d67649b8f3779a9aa15fab876';
const runtimeDefault = process.env.TAKEFORM_RUNTIME;
const browserDefault = process.env.TAKEFORM_BROWSER_EXECUTABLE;
const adapterDirectory = resolve(fileURLToPath(new URL('.', import.meta.url)));
const browserWrapper = resolve(adapterDirectory, '../runtime/browser/secure-browser-launcher.sh');
const execute = promisify(execFile);
const browserModule = String.raw`const state = await fetch('./state.json').then((response) => response.json());
const root = document.getElementById('root');
const nodes = new Map();
for (const source of Object.values(state.sources)) {
  const node = document.createElement(source.element === 'video' ? 'video' : 'img');
  node.src = source.path;
  node.muted = true;
  node.playsInline = true;
  node.preload = 'auto';
  node.style.position = 'absolute';
  node.style.objectFit = 'cover';
  root.append(node);
  nodes.set(source.id, node);
}
let pending = Promise.resolve();
function seconds(value) { return value.ticks / value.timescale; }
function seek(time) {
  const frame = Math.max(0, Math.min(state.frames.length - 1, Math.round(time * state.rate.num / state.rate.den)));
  const current = state.frames[frame];
  const active = new Set();
  const waits = [];
  for (const layer of current.pictureLayers) {
    const node = nodes.get(layer.sourceId);
    if (!node) continue;
    active.add(layer.sourceId);
    const geometry = layer.geometry;
    node.style.display = 'block';
    node.style.left = (geometry.x * 100) + '%';
    node.style.top = (geometry.y * 100) + '%';
    node.style.width = (geometry.width * 100) + '%';
    node.style.height = (geometry.height * 100) + '%';
    node.style.opacity = String(layer.opacity);
    node.style.boxSizing = 'border-box';
    node.style.border = (geometry.border.width * 1920) + 'px solid ' + geometry.border.color;
    node.style.transform = 'translate(' + ((geometry.translateX ?? 0) * 100) + '%, ' + ((geometry.translateY ?? 0) * 100) + '%) rotate(' + geometry.rotationDegrees + 'deg)';
    if (node instanceof HTMLVideoElement) {
      const sourceTime = seconds(layer.sourceTime);
      if (Math.abs(node.currentTime - sourceTime) > 0.02) {
        waits.push(new Promise((resolveSeek) => { node.onseeked = () => resolveSeek(); node.currentTime = sourceTime; }));
      }
    }
  }
  for (const [id, node] of nodes) if (!active.has(id)) node.style.display = 'none';
  pending = Promise.all(waits);
  return pending;
}
window.__hf = {duration: state.durationSeconds, seek};
window.__hfWaitForSeekCompletion = () => pending;
seek(0);`;

function args(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (!argv[index].startsWith('--')) throw new Error('Invalid argument');
    values[argv[index].slice(2)] = argv[index + 1];
    index += 1;
  }
  return values;
}

function hash(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function mediaPreparationReceipt(manifestBytes, manifest, entries) {
  return {
    derivativeHashes: entries.map((entry) => ({sha256: entry.sha256, sourceId: entry.sourceId})),
    rawManifestSha256: hash(manifestBytes),
    semanticManifestDigest: manifest.manifestDigest
  };
}

function receiptJson(value, attemptRoot) {
  return JSON.stringify(value, (key, item) => typeof item === 'string' ? item.replaceAll(attemptRoot, '.') : item, 2);
}

export function createAttemptProgress(attemptRoot, startedAt = Date.now()) {
  const path = join(attemptRoot, 'progress.ndjson');
  let pending = Promise.resolve();

  const emit = (event) => {
    const line = `${JSON.stringify({schemaVersion: 1, atMs: Date.now() - startedAt, ...event})}\n`;
    pending = pending.then(() => appendFile(path, line));
    pending.catch(() => {});
    return pending;
  };

  return {emit, flush: () => pending, path};
}

async function importProducer(runtime) {
  const entry = join(runtime, 'node_modules/@hyperframes/producer/dist/index.js');
  return import(pathToFileURL(entry).href);
}

async function directoryBytes(directory) {
  let total = 0;
  for (const entry of await readdir(directory, {withFileTypes: true})) {
    const item = join(directory, entry.name);
    if (entry.isDirectory()) total += await directoryBytes(item);
    else if (entry.isFile()) total += (await stat(item)).size;
  }
  return total;
}

export function ownedProcessTree(rows, rootPid) {
  const owned = new Set([rootPid]);
  for (let changed = true; changed;) {
    changed = false;
    for (const row of rows) if (owned.has(row.ppid) && !owned.has(row.pid)) { owned.add(row.pid); changed = true; }
  }
  return rows.filter((row) => owned.has(row.pid));
}

async function processTreeSample(rootPid) {
  const {stdout} = await execute('ps', ['-axo', 'pid=,ppid=,rss=,pcpu=,comm=']);
  const rows = stdout.trim().split('\n').filter(Boolean).map((line) => {
    const [pid, ppid, rssKiB, cpuPercent, ...command] = line.trim().split(/\s+/);
    return {cpuPercent: Number(cpuPercent), name: basename(command.join(' ')), pid: Number(pid), ppid: Number(ppid), residentBytes: Number(rssKiB) * 1024};
  });
  return ownedProcessTree(rows, rootPid);
}

export function framePayload(snapshot, fixtureId, prepared = new Map()) {
  const fixture = snapshot._manifests[fixtureId];
  const frames = Array.from({length: fixture.manifest.expected.frameCount}, (_, frame) => frameState(snapshot, fixtureId, frame));
  const selected = new Set(frames.flatMap((state) => state.pictureLayers.map((layer) => layer.sourceId)));
  const sources = Object.fromEntries(fixture.manifest.sources.filter((source) => selected.has(source.id)).map((source) => {
    const path = prepared.get(source.id)?.path ?? source.path;
    return [source.id, {element: ['video', 'livePhotoVideo'].includes(source.kind) ? 'video' : 'image', id: source.id, path: `media/${source.id}${path.slice(path.lastIndexOf('.'))}`}];
  }));
  return {durationSeconds: fixture.manifest.expected.outputDuration.ticks / fixture.manifest.expected.outputDuration.timescale, frames, rate: fixture.rate, sources};
}

async function writeProject(snapshot, fixtureId, fixtureRoot, project, prepared, derivativeRoot) {
  const payload = framePayload(snapshot, fixtureId, prepared);
  const fixtureDirectory = join(fixtureRoot, fixtureId);
  await mkdir(project, {recursive: true});
  const media = join(project, 'media');
  await mkdir(media, {recursive: true});
  for (const source of snapshot._manifests[fixtureId].manifest.sources.filter((source) => source.id in payload.sources)) {
    const entry = prepared.get(source.id);
    await symlink(entry ? resolve(derivativeRoot, entry.path) : resolve(fixtureDirectory, source.path), join(media, basename(payload.sources[source.id].path)));
  }
  await writeFile(join(project, 'state.json'), JSON.stringify(payload));
  await writeFile(join(project, 'composition.mjs'), browserModule);
  await writeFile(join(project, 'index.html'), '<!doctype html><html><head><meta charset="utf-8"><style>html,body,#root{margin:0;width:100%;height:100%;overflow:hidden;background:#101114}#root{position:relative}</style></head><body><main id="root" data-composition-id="takeform-montage" data-width="1920" data-height="1080" data-duration="16" data-no-timeline data-probe-marker="hyperframes-montage"></main><script type="module" src="./composition.mjs"></script></body></html>');
  return hash(JSON.stringify(payload));
}

export class HyperframesAdapter {
  constructor({browser, fixtureRoot, mediaPrep, runtime}) {
    this.browser = browser;
    this.fixtureRoot = fixtureRoot;
    this.mediaPrep = mediaPrep;
    this.runtime = runtime;
    this.controllers = new Map();
  }

  async start({fixtureId, attemptRoot}) {
    if (!['M', 'T', 'L'].includes(fixtureId)) throw new Error(`Unsupported fixture ${fixtureId}`);
    const snapshot = await freezeSnapshot({acceptedCommit, fixtureRoot: this.fixtureRoot});
    if (!this.mediaPrep?.modulePath || !this.mediaPrep?.manifestPath || !this.mediaPrep?.derivativeRoot) throw new Error('shared media preparation is required');
    const loader = await import(pathToFileURL(resolve(this.mediaPrep.modulePath)).href);
    const manifestBytes = await readFile(this.mediaPrep.manifestPath);
    const manifest = JSON.parse(manifestBytes.toString('utf8'));
    const expectedOriginals = {
      ...loader.expectedOriginalsFromSnapshot(snapshot, 'M'),
      ...loader.expectedOriginalsFromSnapshot(snapshot, fixtureId)
    };
    const preparedEntries = await loader.validateManifest(manifest, {derivativeRoot: this.mediaPrep.derivativeRoot, expectedOriginals});
    const prepared = new Map(preparedEntries.map((entry) => [entry.sourceId, entry]));
    const mediaPreparation = mediaPreparationReceipt(manifestBytes, manifest, preparedEntries);
    const fixture = snapshot._manifests[fixtureId].manifest;
    const project = join(attemptRoot, 'project');
    const work = join(attemptRoot, 'work');
    const output = join(attemptRoot, 'output', `${fixtureId}.mp4`);
    await mkdir(join(attemptRoot, 'output'), {recursive: true});
    await mkdir(work, {recursive: true});
    const attempt = createAttempt({id: basename(attemptRoot), snapshot, backend: {identity: 'hyperframes', version: '0.8.39', kind: 'renderer'}, attemptRoot, outputPath: output, scratchPaths: [project, work]});
    const fileSystem = await statfs(attemptRoot);
    const freeBytes = Number(fileSystem.bavail * fileSystem.bsize);
    const reservation = reserveStorage({route: 'streaming', width: fixture.canonicalPlan.width, height: fixture.canonicalPlan.height, frameCount: fixture.expected.frameCount, expectedOutputBytes: 256 * 1024 * 1024, decodeCacheBytes: 512 * 1024 * 1024, pipelineBufferBytes: 512 * 1024 * 1024, runtimeFreeFloorBytes: 1024 * 1024 * 1024, freeBytes});
    const bundleHash = fixtureId === 'M'
      ? await writeProject(snapshot, fixtureId, this.fixtureRoot, project, prepared, this.mediaPrep.derivativeRoot)
      : await writeTlProject(snapshot, fixtureId, this.fixtureRoot, project, prepared, this.mediaPrep.derivativeRoot);
    const producer = await importProducer(this.runtime);
    const producerConfig = {...producer.DEFAULT_CONFIG, browserGpuMode: 'software', browserTimeout: 30000, chromePath: browserWrapper, enableBrowserPool: false, enableStreamingEncode: true, forceScreenshot: false, lowMemoryMode: false, protocolTimeout: 30000, streamingEncodeMaxDurationSeconds: 1801};
    const controller = new AbortController();
    this.controllers.set(attempt.id, controller);
    const progress = [];
    const durableProgress = createAttemptProgress(attemptRoot);
    const processSamples = [];
    let highWaterBytes = 0;
    let lowestFreeBytes = freeBytes;
    const sample = setInterval(async () => {
      const sampleFileSystem = await statfs(attemptRoot);
      lowestFreeBytes = Math.min(lowestFreeBytes, Number(sampleFileSystem.bavail * sampleFileSystem.bsize));
      highWaterBytes = Math.max(highWaterBytes, await directoryBytes(attemptRoot));
      processSamples.push({atMs: Date.now() - started, processes: await processTreeSample(process.pid), residentBytesMeaning: 'per-process resident bytes; sums may double-count shared pages'});
    }, 1000);
    process.env.TAKEFORM_BROWSER_EXECUTABLE = this.browser;
    const job = producer.createRenderJob({entryFile: 'index.html', format: 'mp4', fps: fixture.canonicalPlan.outputFrameRate, hdrMode: 'force-sdr', producerConfig, quality: 'standard', strictness: 'strict', workers: 1});
    const started = Date.now();
    let lastFrame = 0;
    let lastStage = '';
    const recordProgress = (renderJob, message) => {
      const entry = {message: String(message).slice(0, 240), status: String(renderJob.status)};
      progress.push(entry);
      const frame = /^Streaming frame (\d+)\/(\d+)$/.exec(entry.message);
      if (frame) {
        const current = Number(frame[1]);
        const total = Number(frame[2]);
        if (current === 1 || current === total || current - lastFrame >= 60) {
          lastFrame = current;
          durableProgress.emit({phase: 'frame', ...entry, frame: current, totalFrames: total});
        }
        return;
      }
      const stage = `${entry.status}:${entry.message}`;
      if (stage !== lastStage) {
        lastStage = stage;
        durableProgress.emit({phase: 'stage', ...entry});
      }
    };
    try {
      await durableProgress.emit({phase: 'initial', status: job.status, message: 'Render job created'});
      await producer.executeRenderJob(job, project, output, recordProgress, controller.signal);
      await durableProgress.flush();
      highWaterBytes = Math.max(highWaterBytes, await directoryBytes(attemptRoot));
      const finished = await finishAttempt(attempt, {status: job.status === 'complete' ? 'completed' : 'failed'});
      const cleaned = await cleanupAttemptScratch(finished);
      await durableProgress.emit({phase: 'terminal', status: String(job.status), message: job.status === 'complete' ? 'Render complete' : 'Render job returned'});
      await durableProgress.flush();
      const result = {attempt: cleaned, bundleHash, elapsedMs: Date.now() - started, highWaterBytes, jobStatus: job.status, lowestFreeBytes, mediaPreparation, processSamples, progress, progressLog: {path: './progress.ndjson', schemaVersion: 1}, reservation, snapshotId: snapshot.snapshotId, samplingBlindSpots: 'one-second cadence; processes born and exited between samples are not observed'};
      await writeFile(join(attemptRoot, 'receipt.json'), receiptJson(result, attemptRoot));
      return result;
    } catch (error) {
      const finished = await finishAttempt(attempt, {status: controller.signal.aborted ? 'interrupted' : 'failed'});
      const cleaned = await cleanupAttemptScratch(finished);
      await durableProgress.emit({phase: 'terminal', status: controller.signal.aborted ? 'interrupted' : 'failed', message: 'Render terminated'}).catch(() => {});
      await durableProgress.flush().catch(() => {});
      const result = {attempt: cleaned, bundleHash, elapsedMs: Date.now() - started, error: error instanceof Error ? error.message.slice(0, 400) : 'unknown', highWaterBytes, lowestFreeBytes, mediaPreparation, processSamples, progress, progressLog: {path: './progress.ndjson', schemaVersion: 1}, reservation, snapshotId: snapshot.snapshotId, samplingBlindSpots: 'one-second cadence; processes born and exited between samples are not observed'};
      await writeFile(join(attemptRoot, 'receipt.json'), receiptJson(result, attemptRoot));
      return result;
    } finally {
      clearInterval(sample);
      this.controllers.delete(attempt.id);
    }
  }

  cancel(attemptId) {
    const controller = this.controllers.get(attemptId);
    if (!controller) throw new Error('Unknown active attempt');
    controller.abort();
  }

  restart({fixtureId, previousAttemptId, attemptRoot}) {
    if (basename(attemptRoot) === previousAttemptId) throw new Error('A restart requires a new attempt id');
    if (this.controllers.has(previousAttemptId)) this.cancel(previousAttemptId);
    return this.start({fixtureId, attemptRoot});
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const options = args(process.argv.slice(2));
  const adapter = new HyperframesAdapter({browser: options.browser ?? browserDefault, fixtureRoot: options['fixture-root'], mediaPrep: {derivativeRoot: options['derivative-root'], manifestPath: options['media-prep-manifest'], modulePath: options['media-prep-module']}, runtime: options.runtime ?? runtimeDefault});
  const result = await adapter.start({fixtureId: options.fixture ?? 'M', attemptRoot: resolve(options['attempt-root'])});
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
