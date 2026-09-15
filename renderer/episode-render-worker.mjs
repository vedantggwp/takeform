import {createHash} from 'node:crypto';
import {mkdir, readFile, rename, stat, symlink, writeFile} from 'node:fs/promises';
import {basename, extname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const here = resolve(fileURLToPath(new URL('.', import.meta.url)));
const schemaVersion = 1;

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

function requestHash(request) {
  return hash(JSON.stringify(request.snapshot));
}

function activeAt(range, time) {
  const start = seconds(range.start);
  const end = start + seconds(range.duration);
  return time >= start && time < end;
}

function sourceTime(occurrence, compositionTime) {
  const source = normalizedSource(occurrence.source);
  if (source.type !== 'video') return null;
  const output = occurrence.outputRange;
  const outputDuration = seconds(output.duration);
  if (outputDuration <= 0) fail('INVALID_RANGE', 'Occurrence output duration must be positive');
  return seconds(source.start) + (compositionTime - seconds(output.start)) * seconds(source.duration) / outputDuration;
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

function styleFor(rect, layer, order) {
  return {
    display: 'none',
    height: `${seconds(rect.height) * 100}%`,
    left: `${seconds(rect.x) * 100}%`,
    objectFit: 'cover',
    position: 'absolute',
    top: `${seconds(rect.y) * 100}%`,
    width: `${seconds(rect.width) * 100}%`,
    zIndex: String(layer * 1000 + order),
  };
}

function sortedOccurrences(composition) {
  return [...composition.occurrences].sort((left, right) => left.order - right.order);
}

function sortedCaptions(composition) {
  return [...composition.captions].sort((left, right) => left.layer - right.layer || left.order - right.order);
}

export function validateRequest(request) {
  if (!request || request.schemaVersion !== schemaVersion) fail('UNSUPPORTED_SCHEMA', 'Worker request schema is unsupported');
  if (!request.jobID || !request.attemptID || !request.snapshot || !request.stageDirectory || !request.outputFileName || basename(request.outputFileName) !== request.outputFileName) {
    fail('INVALID_REQUEST', 'Worker request is missing its required identity or stage fields');
  }
  const {snapshot} = request;
  if (!snapshot.projectID || !snapshot.episodeID || !snapshot.compositionDigest || !snapshot.composition || !Array.isArray(snapshot.assets)) {
    fail('INVALID_SNAPSHOT', 'Worker request has an incomplete render snapshot');
  }
  if (!Array.isArray(request.resolvedObjects) || request.resolvedObjects.length === 0) fail('MISSING_OBJECTS', 'Worker request has no resolved objects');
  if (snapshot.composition.clipAudioPolicy !== 'muted') fail('UNSUPPORTED_AUDIO_POLICY', 'This worker supports only the declared silent montage policy');
  const objects = new Map(request.resolvedObjects.map((entry) => [entry.assetID, entry]));
  for (const occurrence of snapshot.composition.occurrences) {
    const object = objects.get(occurrence.assetID);
    if (!object || object.digest !== occurrence.assetDigest || !object.localPath) fail('OBJECT_BINDING_MISMATCH', 'Occurrence does not match a resolved object');
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

async function runtimeVersions(runtime) {
  const packages = ['@hyperframes/producer', '@hyperframes/engine'];
  return Object.fromEntries(await Promise.all(packages.map(async (name) => {
    const metadata = JSON.parse(await readFile(join(runtime, 'node_modules', name, 'package.json'), 'utf8'));
    return [name, metadata.version];
  })));
}

export async function runAttempt(request, {signal} = {}) {
  const {project} = await writeProject(request);
  const output = join(request.stageDirectory, request.outputFileName);
  const runtime = resolve(request.runtime.runtimeRoot);
  const producer = await import(pathToFileURL(join(runtime, 'node_modules/@hyperframes/producer/dist/index.js')).href);
  const progress = [];
  const job = producer.createRenderJob({entryFile: 'index.html', format: 'mp4', fps: {num: request.snapshot.composition.output.frameRate.value, den: request.snapshot.composition.output.frameRate.timescale}, quality: 'standard', workers: 1});
  const receiptPath = join(request.stageDirectory, 'attempt-receipt.json');
  try {
    await producer.executeRenderJob(job, project, output, (_job, message) => progress.push({message: String(message).slice(0, 240)}), signal);
    const outputStat = await stat(output);
    const receipt = {schemaVersion, jobID: request.jobID, attemptID: request.attemptID, outcome: 'succeeded', input: {compositionDigest: request.snapshot.compositionDigest, snapshotSHA256: requestHash(request), assets: request.snapshot.assets.map(({id, digest}) => ({id, digest}))}, runtime: {nodeVersion: process.version, packages: await runtimeVersions(runtime)}, progress: {kind: progress.length ? 'callback' : 'indeterminate', events: progress}, artifact: {fileName: basename(output), byteLength: outputStat.size, sha256: hash(await readFile(output))}};
    await atomicJson(receiptPath, receipt);
    return receipt;
  } catch (error) {
    const receipt = {schemaVersion, jobID: request.jobID, attemptID: request.attemptID, outcome: signal?.aborted ? 'cancelled' : 'failed', input: {compositionDigest: request.snapshot.compositionDigest, snapshotSHA256: requestHash(request)}, progress: {kind: progress.length ? 'callback' : 'indeterminate', events: progress}, error: {code: error?.code ?? 'RENDER_FAILED', phase: 'producer'}};
    await atomicJson(receiptPath, receipt);
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
