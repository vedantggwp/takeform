import {createHash} from 'node:crypto';
import {mkdir, readdir, stat, statfs, symlink, writeFile} from 'node:fs/promises';
import {basename, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {createAttempt, finishAttempt, freezeSnapshot, frameState, reserveStorage} from '../common/index.mjs';

const acceptedCommit = '8a3daf1978093a3d67649b8f3779a9aa15fab876';
const runtimeDefault = process.env.TAKEFORM_RUNTIME;
const browserDefault = process.env.TAKEFORM_BROWSER_EXECUTABLE;
const adapterDirectory = resolve(fileURLToPath(new URL('.', import.meta.url)));
const browserWrapper = resolve(adapterDirectory, '../runtime/browser/secure-browser-launcher.sh');
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

function receiptJson(value, attemptRoot) {
  return JSON.stringify(value, (key, item) => typeof item === 'string' ? item.replaceAll(attemptRoot, '.') : item, 2);
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

export function framePayload(snapshot, fixtureId) {
  const fixture = snapshot._manifests[fixtureId];
  const frames = Array.from({length: fixture.manifest.expected.frameCount}, (_, frame) => frameState(snapshot, fixtureId, frame));
  const selected = new Set(frames.flatMap((state) => state.pictureLayers.map((layer) => layer.sourceId)));
  const sources = Object.fromEntries(fixture.manifest.sources.filter((source) => selected.has(source.id)).map((source) => [source.id, {element: ['video', 'livePhotoVideo'].includes(source.kind) ? 'video' : 'image', id: source.id, path: `media/${source.path.split('/').at(-1)}`}]));
  return {durationSeconds: fixture.manifest.expected.outputDuration.ticks / fixture.manifest.expected.outputDuration.timescale, frames, rate: fixture.rate, sources};
}

async function writeProject(snapshot, fixtureId, fixtureRoot, project) {
  const payload = framePayload(snapshot, fixtureId);
  const fixtureDirectory = join(fixtureRoot, fixtureId);
  await mkdir(project, {recursive: true});
  await symlink(join(fixtureDirectory, 'media'), join(project, 'media'));
  await writeFile(join(project, 'state.json'), JSON.stringify(payload));
  await writeFile(join(project, 'composition.mjs'), browserModule);
  await writeFile(join(project, 'index.html'), '<!doctype html><html><head><meta charset="utf-8"><style>html,body,#root{margin:0;width:100%;height:100%;overflow:hidden;background:#101114}#root{position:relative}</style></head><body><main id="root" data-composition-id="takeform-montage" data-width="1920" data-height="1080" data-duration="16" data-no-timeline data-probe-marker="hyperframes-montage"></main><script type="module" src="./composition.mjs"></script></body></html>');
  return hash(JSON.stringify(payload));
}

export class HyperframesAdapter {
  constructor({browser, fixtureRoot, runtime}) {
    this.browser = browser;
    this.fixtureRoot = fixtureRoot;
    this.runtime = runtime;
    this.controllers = new Map();
  }

  async start({fixtureId, attemptRoot}) {
    if (fixtureId !== 'M') throw new Error('This lease authorizes M only');
    const snapshot = await freezeSnapshot({acceptedCommit, fixtureRoot: this.fixtureRoot});
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
    const bundleHash = await writeProject(snapshot, fixtureId, this.fixtureRoot, project);
    const producer = await importProducer(this.runtime);
    const producerConfig = {...producer.DEFAULT_CONFIG, browserGpuMode: 'software', browserTimeout: 30000, chromePath: browserWrapper, enableBrowserPool: false, enableStreamingEncode: true, forceScreenshot: false, lowMemoryMode: false, protocolTimeout: 30000, streamingEncodeMaxDurationSeconds: 1801};
    const controller = new AbortController();
    this.controllers.set(attempt.id, controller);
    const progress = [];
    let highWaterBytes = 0;
    let lowestFreeBytes = freeBytes;
    const sample = setInterval(async () => {
      const sampleFileSystem = await statfs(attemptRoot);
      lowestFreeBytes = Math.min(lowestFreeBytes, Number(sampleFileSystem.bavail * sampleFileSystem.bsize));
      highWaterBytes = Math.max(highWaterBytes, await directoryBytes(attemptRoot));
    }, 1000);
    process.env.TAKEFORM_BROWSER_EXECUTABLE = this.browser;
    const job = producer.createRenderJob({entryFile: 'index.html', format: 'mp4', fps: fixture.canonicalPlan.outputFrameRate, hdrMode: 'force-sdr', producerConfig, quality: 'standard', strictness: 'strict', workers: 1});
    const started = Date.now();
    try {
      await producer.executeRenderJob(job, project, output, (renderJob, message) => progress.push({message: String(message).slice(0, 240), status: renderJob.status}), controller.signal);
      highWaterBytes = Math.max(highWaterBytes, await directoryBytes(attemptRoot));
      const finished = await finishAttempt(attempt, {status: job.status === 'complete' ? 'completed' : 'failed'});
      const result = {attempt: finished, bundleHash, elapsedMs: Date.now() - started, highWaterBytes, jobStatus: job.status, lowestFreeBytes, progress, reservation, snapshotId: snapshot.snapshotId};
      await writeFile(join(attemptRoot, 'receipt.json'), receiptJson(result, attemptRoot));
      return result;
    } catch (error) {
      const finished = await finishAttempt(attempt, {status: controller.signal.aborted ? 'interrupted' : 'failed'});
      const result = {attempt: finished, bundleHash, elapsedMs: Date.now() - started, error: error instanceof Error ? error.message.slice(0, 400) : 'unknown', highWaterBytes, lowestFreeBytes, progress, reservation, snapshotId: snapshot.snapshotId};
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
  const adapter = new HyperframesAdapter({browser: options.browser ?? browserDefault, fixtureRoot: options['fixture-root'], runtime: options.runtime ?? runtimeDefault});
  const result = await adapter.start({fixtureId: options.fixture ?? 'M', attemptRoot: resolve(options['attempt-root'])});
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
