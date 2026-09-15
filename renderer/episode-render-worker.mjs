import {createHash} from 'node:crypto';
import {execFile as execFileCallback} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {lstat, mkdir, readFile, rename, stat, symlink, writeFile} from 'node:fs/promises';
import {basename, extname, join, resolve} from 'node:path';
import {promisify} from 'node:util';
import {pathToFileURL} from 'node:url';

const schemaVersion = 1;
const execFile = promisify(execFileCallback);
export const runtimeProfile = JSON.parse(readFileSync(new URL('./runtime-profile.json', import.meta.url), 'utf8'));

function fail(code, message) {
  const error = new Error(message);
  error.code = code;
  throw error;
}

function seconds(value) {
  if (!value || !Number.isInteger(value.value) || !Number.isInteger(value.timescale) || value.timescale <= 0) {
    fail('INVALID_RATIONAL', 'Worker request has an invalid rational value');
  }
  return value.value / value.timescale;
}

function hash(value) {
  return createHash('sha256').update(value).digest('hex');
}

function normalizedSource(source) {
  if (source?.type === 'still') return source;
  if (source?.type === 'video' && source.range) return source;
  if (source && Object.hasOwn(source, 'still')) return {type: 'still'};
  if (source && Object.hasOwn(source, 'video')) {
    const video = source.video;
    const range = video?.range ?? video?._0 ?? video;
    if (range?.start && range?.duration) return {type: 'video', range};
  }
  fail('INVALID_SOURCE', 'Worker request has an unsupported source encoding');
}

function sortedOccurrences(composition) {
  return [...composition.occurrences].sort((left, right) => left.order - right.order);
}

function sortedCaptions(composition) {
  return [...composition.captions].sort((left, right) => left.layer - right.layer || left.order - right.order);
}

export function validateRequest(request) {
  if (!request || request.schemaVersion !== schemaVersion) fail('UNSUPPORTED_SCHEMA', 'Worker request schema is unsupported');
  if (!request.jobID || !request.attemptID || !request.snapshot || !/^[a-f0-9]{64}$/.test(request.snapshotSHA256 ?? '') || !request.stageDirectory || !request.outputFileName || basename(request.outputFileName) !== request.outputFileName) {
    fail('INVALID_REQUEST', 'Worker request is missing its required identity or stage fields');
  }
  const {snapshot} = request;
  if (!snapshot.projectID || !snapshot.episodeID || !snapshot.compositionDigest || !snapshot.composition || !Array.isArray(snapshot.assets) || snapshot.format !== 'mp4') {
    fail('INVALID_SNAPSHOT', 'Worker request has an incomplete render snapshot');
  }
  if (!Array.isArray(request.resolvedObjects) || request.resolvedObjects.length === 0) fail('MISSING_OBJECTS', 'Worker request has no resolved objects');
  if (snapshot.composition.clipAudioPolicy !== 'muted') fail('UNSUPPORTED_AUDIO_POLICY', 'This worker supports only the declared silent montage policy');
  const assets = new Map(snapshot.assets.map((asset) => [asset.id, asset]));
  const objects = new Map(request.resolvedObjects.map((entry) => [entry.assetID, entry]));
  if (assets.size !== snapshot.assets.length || objects.size !== request.resolvedObjects.length) {
    fail('DUPLICATE_ASSET_BINDING', 'Worker request contains duplicate asset bindings');
  }
  for (const asset of snapshot.assets) {
    const object = objects.get(asset.id);
    if (!asset.id || !asset.digest || !Number.isInteger(asset.byteLength) || asset.byteLength < 0 || !object || object.digest !== asset.digest || object.byteLength !== asset.byteLength || !object.localPath) {
      fail('OBJECT_BINDING_MISMATCH', 'Snapshot asset does not match its resolved object');
    }
  }
  for (const occurrence of snapshot.composition.occurrences) {
    const object = objects.get(occurrence.assetID);
    if (!assets.has(occurrence.assetID) || !object || object.digest !== occurrence.assetDigest || !object.localPath) fail('OBJECT_BINDING_MISMATCH', 'Occurrence does not match a resolved object');
    if (!occurrence.outputRect) fail('MISSING_OUTPUT_RECT', 'Occurrence has no normalized output rectangle');
    seconds(occurrence.outputRange.start); seconds(occurrence.outputRange.duration);
    for (const key of ['x', 'y', 'width', 'height']) seconds(occurrence.outputRect[key]);
    const source = normalizedSource(occurrence.source);
    if (source.type === 'video') {
      seconds(source.range.start); seconds(source.range.duration);
    }
  }
  return objects;
}

export function compositionModule(composition, media) {
  const payload = JSON.stringify({captions: sortedCaptions(composition), composition, media});
  return `const state=${payload};
const root=document.getElementById('takeform-composition');
const nodes=new Map();
const captions=new Map();
const seconds=(value)=>value.value/value.timescale;
const active=(range,time)=>time>=seconds(range.start)&&time<seconds(range.start)+seconds(range.duration);
const sourceOf=(source)=>source.type?source:(Object.hasOwn(source,'still')?{type:'still'}:{type:'video',range:source.video.range??source.video._0??source.video});
const videoTime=(occurrence,time)=>{const source=sourceOf(occurrence.source);return seconds(source.range.start)+(time-seconds(occurrence.outputRange.start))*seconds(source.range.duration)/seconds(occurrence.outputRange.duration)};
for(const occurrence of [...state.composition.occurrences].sort((a,b)=>a.order-b.order)){
 const source=state.media[occurrence.id]; const node=document.createElement(sourceOf(occurrence.source).type==='video'?'video':'img');
 node.src=source; node.muted=true; node.playsInline=true; node.preload='metadata'; node.style.position='absolute'; node.style.objectFit='cover';
 node.style.left=(seconds(occurrence.outputRect.x)*100)+'%'; node.style.top=(seconds(occurrence.outputRect.y)*100)+'%'; node.style.width=(seconds(occurrence.outputRect.width)*100)+'%'; node.style.height=(seconds(occurrence.outputRect.height)*100)+'%'; node.style.zIndex=String(occurrence.layer*1000+occurrence.order); node.style.display='none'; root.append(node); nodes.set(occurrence.id,node);
}
for(const caption of state.captions){const node=document.createElement('div');node.textContent=caption.text;node.style.position='absolute';node.style.inset='0';node.style.display='none';node.style.zIndex=String(1000000+caption.layer*1000+caption.order);root.append(node);captions.set(caption.id,node);}
let pending=Promise.resolve();
function seek(time){const waits=[];for(const occurrence of state.composition.occurrences){const node=nodes.get(occurrence.id);const visible=active(occurrence.outputRange,time);node.style.display=visible?'block':'none';if(visible&&node instanceof HTMLVideoElement){const target=videoTime(occurrence,time);if(Math.abs(node.currentTime-target)>0.002)waits.push(new Promise((done)=>{node.addEventListener('seeked',done,{once:true});node.currentTime=target;}));}}for(const caption of state.captions)captions.get(caption.id).style.display=active(caption.outputRange,time)?'block':'none';pending=Promise.all(waits);return pending;}
window.__hf={duration:seconds(state.composition.output.duration),seek};window.__hfWaitForSeekCompletion=()=>pending;seek(0);`;
}

export async function writeProject(request) {
  const objects = validateRequest(request);
  const project = join(request.stageDirectory, 'project');
  const mediaDirectory = join(project, 'media');
  await mkdir(mediaDirectory, {recursive: true});
  const media = {};
  for (const occurrence of sortedOccurrences(request.snapshot.composition)) {
    const object = objects.get(occurrence.assetID);
    const fileName = `${occurrence.id}${extname(object.localPath) || '.bin'}`;
    const destination = join(mediaDirectory, fileName);
    await symlink(resolve(object.localPath), destination);
    media[occurrence.id] = `media/${fileName}`;
  }
  await writeFile(join(project, 'composition.mjs'), compositionModule(request.snapshot.composition, media));
  await writeFile(join(project, 'index.html'), `<!doctype html><meta charset="utf-8"><style>html,body,#takeform-composition{margin:0;width:100%;height:100%;overflow:hidden;background:#000}#takeform-composition{position:relative}</style><main id="takeform-composition" data-composition-id="takeform-episode" data-width="${request.snapshot.composition.output.width}" data-height="${request.snapshot.composition.output.height}" data-duration="${seconds(request.snapshot.composition.output.duration)}" data-no-timeline></main><script type="module" src="./composition.mjs"></script>`);
  return {media, project};
}

async function atomicJson(path, value) {
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {flag: 'wx'});
  await rename(temporary, path);
}

function profileRelativePath(path, label) {
  if (typeof path !== 'string' || !path || path.startsWith('/') || path.split('/').some((part) => !part || part === '.' || part === '..')) {
    fail('INVALID_RUNTIME_PROFILE', `${label} must be a contained relative path`);
  }
  return path;
}

async function requireContainedProfileFile(root, relativePath, label, executable = false) {
  const parts = profileRelativePath(relativePath, label).split('/');
  let directory = root;
  for (const part of parts.slice(0, -1)) {
    directory = join(directory, part);
    let entry;
    try {
      entry = await lstat(directory);
    } catch {
      fail('RUNTIME_PROFILE_PATH_UNSAFE', `${label} parent is unavailable`);
    }
    if (!entry.isDirectory() || entry.isSymbolicLink()) fail('RUNTIME_PROFILE_PATH_UNSAFE', `${label} parent is not a real directory`);
  }
  const candidate = join(directory, parts[parts.length - 1]);
  let entry;
  try {
    entry = await lstat(candidate);
  } catch {
    fail('RUNTIME_PROFILE_PATH_UNSAFE', `${label} is unavailable`);
  }
  if (!entry.isFile() || entry.isSymbolicLink() || executable && (entry.mode & 0o111) === 0) {
    fail('RUNTIME_PROFILE_PATH_UNSAFE', `${label} is not a regular${executable ? ' executable' : ''} file`);
  }
  return candidate;
}

async function requireExecutable(path, label) {
  if (typeof path !== 'string' || !path.startsWith('/')) fail('INVALID_RUNTIME', `${label} must be an absolute executable path`);
  const lexical = resolve(path);
  if (lexical !== path) fail('INVALID_RUNTIME', `${label} must be a canonical executable path`);
  try {
    const entry = await lstat(lexical);
    if (!entry.isFile() || entry.isSymbolicLink() || (entry.mode & 0o111) === 0) fail('RUNTIME_EXECUTABLE_UNAVAILABLE', `${label} is not a regular executable`);
  } catch {
    fail('RUNTIME_EXECUTABLE_UNAVAILABLE', `${label} is not executable`);
  }
  return lexical;
}

async function requireProfileLauncher(root, kind) {
  const candidates = runtimeProfile.launchers?.filter((entry) => entry?.kind === kind) ?? [];
  if (candidates.length !== 1) fail('INVALID_RUNTIME_PROFILE', `Runtime profile has an ambiguous ${kind} launcher`);
  const [launcher] = candidates;
  if (!launcher || !/^[a-f0-9]{64}$/.test(launcher.sha256 ?? '')) fail('INVALID_RUNTIME_PROFILE', `Runtime profile has no valid ${kind} launcher`);
  const path = await requireContainedProfileFile(root, launcher.path, `${kind} launcher`, true);
  if (hash(await readFile(path)) !== launcher.sha256) fail('RUNTIME_LAUNCHER_MISMATCH', `${kind} launcher does not match the runtime profile`);
  return {kind, path, relativePath: launcher.path, sha256: launcher.sha256};
}

async function requireProfileWorker(root) {
  const worker = runtimeProfile.worker;
  if (!worker || !/^[a-f0-9]{64}$/.test(worker.sha256 ?? '')) fail('INVALID_RUNTIME_PROFILE', 'Runtime profile has no valid worker hash');
  const path = await requireContainedProfileFile(root, worker.path, 'worker');
  if (hash(await readFile(path)) !== worker.sha256) fail('RUNTIME_WORKER_MISMATCH', 'Worker does not match the runtime profile');
  return {path: worker.path, sha256: worker.sha256};
}

async function executableFacts(path, label, arguments_) {
  let stdout;
  try {
    ({stdout} = await execFile(path, arguments_, {
      env: {HOME: process.env.HOME ?? '', PATH: ''},
      maxBuffer: 64 * 1024,
      timeout: 5_000,
    }));
  } catch {
    fail('RUNTIME_VERSION_UNAVAILABLE', `${label} did not return bounded version facts`);
  }
  const lines = String(stdout).split(/\r?\n/).filter(Boolean);
  return {
    sha256: hash(await readFile(path)),
    version: lines[0] ?? '',
    buildConfiguration: lines.find((line) => line.startsWith('configuration:')) ?? undefined,
  };
}

export async function validateRuntime(runtime) {
  if (!runtime || typeof runtime.runtimeRoot !== 'string' || !runtime.runtimeRoot.startsWith('/')) fail('INVALID_RUNTIME', 'Runtime root must be an absolute path');
  if (runtime.nodeVersion !== runtimeProfile.nodeVersion || process.version !== runtimeProfile.nodeVersion) fail('NODE_VERSION_MISMATCH', 'Worker Node version does not match the pinned runtime profile');
  const root = resolve(runtime.runtimeRoot);
  if (root !== runtime.runtimeRoot) fail('INVALID_RUNTIME', 'Runtime root must be canonical');
  try {
    const rootEntry = await lstat(root);
    if (!rootEntry.isDirectory() || rootEntry.isSymbolicLink()) fail('INVALID_RUNTIME', 'Runtime root must be a real directory');
  } catch (error) {
    if (error?.code === 'INVALID_RUNTIME') throw error;
    fail('INVALID_RUNTIME', 'Runtime root is unavailable');
  }
  const packages = [];
  for (const {path, name, version} of runtimeProfile.packages) {
    let metadata;
    try {
      metadata = JSON.parse(await readFile(join(root, 'node_modules', profileRelativePath(path, `${name} package`), 'package.json'), 'utf8'));
    } catch {
      fail('RUNTIME_PACKAGE_UNAVAILABLE', `${name} package metadata is unavailable`);
    }
    if (metadata.name !== name || metadata.version !== version) fail('RUNTIME_PACKAGE_MISMATCH', `${name} package identity does not match the pinned runtime`);
    packages.push({path, name, version});
  }
  const browserWrapper = await requireProfileLauncher(root, 'browser');
  const worker = await requireProfileWorker(root);
  const browserTargetExecutable = await requireExecutable(runtime.browserTargetExecutable, 'Browser target');
  const ffmpegExecutable = await requireExecutable(runtime.ffmpegExecutable, 'FFmpeg');
  const ffprobeExecutable = await requireExecutable(runtime.ffprobeExecutable, 'FFprobe');
  return {
    browserWrapperExecutable: browserWrapper.path,
    browserTargetExecutable,
    ffmpegExecutable,
    ffprobeExecutable,
    nodeVersion: process.version,
    packages,
    runtimeRoot: root,
    receiptFacts: {
      browserWrapper: {kind: browserWrapper.kind, sha256: browserWrapper.sha256},
      worker: {sha256: worker.sha256},
      browserTarget: await executableFacts(browserTargetExecutable, 'Browser target', ['--version']),
      ffmpeg: await executableFacts(ffmpegExecutable, 'FFmpeg', ['-version']),
      ffprobe: await executableFacts(ffprobeExecutable, 'FFprobe', ['-version']),
    },
  };
}

function receiptInput(request) {
  return {
    compositionDigest: request.snapshot.compositionDigest,
    snapshotSHA256: request.snapshotSHA256,
    assets: request.snapshot.assets.map(({id, digest}) => ({id, digest})),
  };
}

async function writeFailureReceipt(request, receiptPath, progress, error, signal) {
  const receipt = {
    schemaVersion,
    jobID: request.jobID,
    attemptID: request.attemptID,
    outcome: signal?.aborted ? 'cancelled' : 'failed',
    input: request.snapshot ? receiptInput(request) : undefined,
    progress: {kind: progress.length ? 'callback' : 'indeterminate', events: progress},
    error: {code: error?.code ?? 'RENDER_FAILED', phase: 'worker'},
  };
  await atomicJson(receiptPath, receipt);
}

export async function runAttempt(request, {signal} = {}) {
  const progress = [];
  const receiptPath = join(request.stageDirectory, 'attempt-receipt.json');
  try {
    validateRequest(request);
    if (signal?.aborted) fail('CANCELLED_BEFORE_START', 'Worker attempt was cancelled before it started');
    const runtime = await validateRuntime(request.runtime);
    const {project} = await writeProject(request);
    const output = join(request.stageDirectory, request.outputFileName);
    // HyperFrames reads these documented executable overrides while its modules initialize.
    process.env.HYPERFRAMES_FFMPEG_PATH = runtime.ffmpegExecutable;
    process.env.HYPERFRAMES_FFPROBE_PATH = runtime.ffprobeExecutable;
    process.env.TAKEFORM_BROWSER_EXECUTABLE = runtime.browserTargetExecutable;
    const producer = await import(pathToFileURL(join(runtime.runtimeRoot, 'node_modules/@hyperframes/producer/dist/index.js')).href);
    const producerConfig = {...producer.DEFAULT_CONFIG, browserGpuMode: 'software', chromePath: runtime.browserWrapperExecutable, enableBrowserPool: false};
    const job = producer.createRenderJob({entryFile: 'index.html', format: request.snapshot.format, fps: {num: request.snapshot.composition.output.frameRate.value, den: request.snapshot.composition.output.frameRate.timescale}, producerConfig, quality: 'standard', strictness: 'strict', workers: 1});
    await producer.executeRenderJob(job, project, output, (_job, message) => progress.push({message: String(message).slice(0, 240)}), signal);
    const outputStat = await stat(output);
    const receiptRuntime = {nodeVersion: runtime.nodeVersion, packages: runtime.packages, ...runtime.receiptFacts};
    const receipt = {schemaVersion, jobID: request.jobID, attemptID: request.attemptID, outcome: 'succeeded', input: receiptInput(request), runtime: receiptRuntime, progress: {kind: progress.length ? 'callback' : 'indeterminate', events: progress}, artifact: {fileName: basename(output), byteLength: outputStat.size, sha256: hash(await readFile(output))}};
    await atomicJson(receiptPath, receipt);
    return receipt;
  } catch (error) {
    await writeFailureReceipt(request, receiptPath, progress, error, signal);
    throw error;
  }
}

async function main(argv) {
  if (argv.length !== 2 || argv[0] !== '--request') fail('USAGE', 'usage: episode-render-worker.mjs --request ATTEMPT_REQUEST.json');
  const request = JSON.parse(await readFile(argv[1], 'utf8'));
  const controller = new AbortController();
  const cancel = () => controller.abort();
  process.once('SIGTERM', cancel);
  process.once('SIGINT', cancel);
  try {
    const receipt = await runAttempt(request, {signal: controller.signal});
    process.stdout.write(`${JSON.stringify({attemptID: receipt.attemptID, outcome: receipt.outcome})}\n`);
  } finally {
    process.removeListener('SIGTERM', cancel);
    process.removeListener('SIGINT', cancel);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`${error.code ?? 'RENDER_FAILED'}: ${error.message}\n`);
    process.exitCode = 1;
  });
}
