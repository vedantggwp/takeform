import {createHash} from 'node:crypto';
import {copyFile, mkdir, readFile, writeFile} from 'node:fs/promises';
import {extname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {freezeSnapshot, frameState} from '../../common/index.mjs';

const ACCEPTED_COMMIT = '8a3daf1978093a3d67649b8f3779a9aa15fab876';
const PLAYER_VERSION = '0.8.39';
const HYPERFRAMES_COMMIT = 'd13a89b6707203a2efe2cfcd4e996e0ad0aa4573';
const HYPERFRAMES_SOURCE = 'https://github.com/heygen-com/hyperframes';
const seconds = value => value.ticks / value.timescale;
const stable = value => Array.isArray(value) ? value.map(stable) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])])) : value;
const json = value => `${JSON.stringify(stable(value), null, 2)}\n`;
const hash = value => createHash('sha256').update(value).digest('hex');
const fileHash = async file => createHash('sha256').update(await readFile(file)).digest('hex');
const cssId = value => value.replaceAll(/[^a-zA-Z0-9_-]/g, '-');

function mLayers(snapshot) {
  const manifest = snapshot._manifests.M.manifest;
  const frameCount = manifest.expected.frameCount;
  const rate = snapshot._manifests.M.rate;
  const all = new Map(manifest.canonicalPlan.occurrences.filter(item => item.role === 'picture').map(item => [item.id, {occurrence: item, states: []}]));
  const verificationFrames = [];
  for (let frame = 0; frame < frameCount; frame += 1) {
    const state = frameState(snapshot, 'M', frame);
    const active = new Map(state.pictureLayers.map(layer => [layer.occurrenceId, layer]));
    const media = [];
    for (const [id, item] of all) {
      const layer = active.get(id);
      item.states.push(layer ? {geometry: layer.geometry, opacity: layer.opacity} : null);
      if (layer && ['video', 'livePhotoVideo'].includes(manifest.sources.find(source => source.id === layer.sourceId)?.kind)) media.push({occurrenceId: id, sourceId: layer.sourceId, sourceTimeSeconds: seconds(layer.sourceTime)});
    }
    verificationFrames.push({frame, media});
  }
  return {durationSeconds: seconds(manifest.expected.outputDuration), frameCount, layers: [...all.values()], rate, verificationFrames};
}

function geometryCss(geometry, opacity) {
  if (!geometry || opacity === 0) return 'opacity:0';
  const border = geometry.border;
  return [
    `left:${geometry.x * 100}%`, `top:${geometry.y * 100}%`, `width:${geometry.width * 100}%`, `height:${geometry.height * 100}%`,
    `opacity:${opacity}`, `transform:translate(${(geometry.translateX ?? 0) * 100}%,${(geometry.translateY ?? 0) * 100}%) rotate(${geometry.rotationDegrees}deg)`,
    border ? `border:${border.width * 1920}px solid ${border.color}` : ''
  ].filter(Boolean).join(';');
}

function keyframes(layer, rate) {
  const id = cssId(layer.occurrence.id);
  const startSeconds = seconds(layer.occurrence.outputRange.start);
  const durationSeconds = seconds(layer.occurrence.outputRange.duration);
  const active = layer.states.flatMap((state, frame) => state ? [{frame, state}] : []);
  if (active.length === 0) throw new Error(`M occurrence has no frame state: ${layer.occurrence.id}`);
  const points = active.map(({frame, state}) => {
    const localSeconds = frame * rate.den / rate.num - startSeconds;
    const percent = Math.max(0, Math.min(100, localSeconds / durationSeconds * 100));
    return `${percent.toFixed(8)}%{${geometryCss(state.geometry, state.opacity)}}`;
  });
  const last = active.at(-1).state;
  if (!points.at(-1).startsWith('100.00000000%')) points.push(`100%{${geometryCss(last.geometry, last.opacity)}}`);
  return `@keyframes ${id}{${points.join('')}}`;
}
function compositionHtml(model, assets) {
  const css = model.layers.map(layer => keyframes(layer, model.rate)).join('\n');
  const elements = model.layers.map(({occurrence}) => {
    const asset = assets.get(occurrence.sourceId);
    if (!asset) throw new Error(`missing staged asset: ${occurrence.sourceId}`);
    const sourceStart = seconds(occurrence.sourceRange.start);
    const outputStart = seconds(occurrence.outputRange.start);
    const outputDuration = seconds(occurrence.outputRange.duration);
    const playbackRate = occurrence.retimeFactor.num / occurrence.retimeFactor.den;
    const tag = asset.element === 'video' ? 'video' : 'img';
    const media = tag === 'video' ? ' muted playsinline preload="auto"' : '';
    return `<${tag} id="layer-${cssId(occurrence.id)}" class="layer" src="${asset.path}" data-start="${outputStart}" data-duration="${outputDuration}" data-media-start="${sourceStart}" data-playback-rate="${playbackRate}" data-takeform-occurrence-id="${occurrence.id}"${media}>`;
  }).join('\n');
  const animations = model.layers.map(({occurrence}) => `#layer-${cssId(occurrence.id)}{animation:${cssId(occurrence.id)} ${seconds(occurrence.outputRange.duration)}s linear both paused}`).join('\n');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#101114}main{position:relative;width:1920px;height:1080px;overflow:hidden}.layer{position:absolute;box-sizing:border-box;object-fit:cover;transform-origin:center;pointer-events:none}${animations}${css}</style></head><body><main id="composition" data-composition-id="takeform-montage" data-width="1920" data-height="1080" data-duration="${model.durationSeconds}">${elements}</main><script src="runtime/hyperframe.runtime.iife.js"></script></body></html>`;
}

function indexHtml(snapshotId, model) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Takeform HyperFrames M Player</title><style>html,body,#stage{margin:0;width:100%;height:100%;overflow:hidden;background:#101114}hyperframes-player{display:block;width:100%;height:100%}</style><script src="runtime/hyperframes-player.global.js"></script></head><body><main id="stage"><hyperframes-player id="player" src="composition.html" width="1920" height="1080" muted></hyperframes-player></main><script type="module">const snapshotId=${JSON.stringify(snapshotId)};const state=await fetch('verification.json',{cache:'no-store'}).then(response=>response.json());const player=document.querySelector('#player');let displayedFrame=0;const iframe=()=>player.shadowRoot?.querySelector('iframe');const paint=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));async function waitForDisplayedFrame(frame){const target=frame*state.rate.den/state.rate.num;player.seek(target);await paint();const documentInPlayer=iframe()?.contentDocument;if(!documentInPlayer)throw new Error('composition iframe is unavailable');for(const media of state.frames[frame].media){const element=documentInPlayer.querySelector('video[data-takeform-occurrence-id="' + CSS.escape(media.occurrenceId) + '"]');if(!element||element.tagName!=='VIDEO')throw new Error('expected video element is unavailable');const deadline=performance.now()+2000;while((element.readyState<HTMLMediaElement.HAVE_CURRENT_DATA||Math.abs(element.currentTime-media.sourceTimeSeconds)>.05)&&performance.now()<deadline)await new Promise(resolve=>setTimeout(resolve,20));if(element.readyState<HTMLMediaElement.HAVE_CURRENT_DATA||Math.abs(element.currentTime-media.sourceTimeSeconds)>.05)throw new Error('requested video frame is not decoded');}displayedFrame=frame;}function respond(command,status){const response={requestID:command.requestID,sessionID:command.sessionID,snapshotID:command.snapshotID,displayedFrame,playback:player.paused?'paused':'playing',status};window.webkit?.messageHandlers?.takeformPreview?.postMessage(response);return response;}window.takeformPreviewCommand=async command=>{if(!command||command.snapshotID!==snapshotId)throw new Error('snapshot identity mismatch');if(command.type==='load'||command.type==='seek'){if(!Number.isInteger(command.frame)||command.frame<0||command.frame>=state.frameCount)throw new Error('frame outside snapshot');await waitForDisplayedFrame(command.frame);return respond(command,'decoded');}if(command.type==='play'){player.play();await paint();return respond(command,'painted');}if(command.type==='pause'){player.pause();await paint();return respond(command,'painted');}throw new Error('unsupported preview command');};if(!player.ready)await new Promise(resolve=>player.addEventListener('ready',resolve,{once:true}));await waitForDisplayedFrame(0);</script></body></html>`;
}

async function runtimeFiles(runtime, bundleRoot) {
  const playerRoot = join(runtime, 'node_modules/@hyperframes/player');
  const coreRoot = join(playerRoot, 'node_modules/@hyperframes/core');
  const player = join(playerRoot, 'dist/hyperframes-player.global.js');
  const core = join(coreRoot, 'dist/hyperframe.runtime.iife.js');
  const [playerPackage, corePackage] = await Promise.all([readFile(join(playerRoot, 'package.json'), 'utf8'), readFile(join(coreRoot, 'package.json'), 'utf8')]);
  if (JSON.parse(playerPackage).version !== PLAYER_VERSION || JSON.parse(corePackage).version !== PLAYER_VERSION) throw new Error(`expected HyperFrames packages ${PLAYER_VERSION}`);
  const license = join(playerRoot, 'LICENSE');
  const licenseText = await readFile(license, 'utf8');
  if (!licenseText.includes('Apache License') || !licenseText.includes('Copyright 2026 HeyGen, Inc.')) throw new Error('expected HyperFrames Apache-2.0 license text');
  const notices = fileURLToPath(new URL('./THIRD_PARTY_NOTICES.md', import.meta.url));
  const noticesText = await readFile(notices, 'utf8');
  for (const value of ['@hyperframes/player@0.8.39', '@hyperframes/core@0.8.39', HYPERFRAMES_SOURCE, 'v0.8.39', HYPERFRAMES_COMMIT]) if (!noticesText.includes(value)) throw new Error('HyperFrames third-party inventory is incomplete');
  await mkdir(join(bundleRoot, 'runtime'), {recursive: true});
  await mkdir(join(bundleRoot, 'LICENSES'), {recursive: true});
  await Promise.all([
    copyFile(player, join(bundleRoot, 'runtime/hyperframes-player.global.js')),
    copyFile(core, join(bundleRoot, 'runtime/hyperframe.runtime.iife.js')),
    copyFile(license, join(bundleRoot, 'LICENSES/Apache-2.0-HeyGen.txt')),
    copyFile(notices, join(bundleRoot, 'THIRD_PARTY_NOTICES.md'))
  ]);
  return {
    coreSha256: await fileHash(core),
    playerSha256: await fileHash(player),
    license: {path: 'LICENSES/Apache-2.0-HeyGen.txt', sha256: await fileHash(license)},
    thirdPartyNotices: {path: 'THIRD_PARTY_NOTICES.md', sha256: await fileHash(notices)}
  };
}

async function stagedAssets({snapshot, fixtureRoot, derivativeRoot, mediaPrepManifestPath, mediaPrepModulePath, bundleRoot}) {
  if (!derivativeRoot || !mediaPrepManifestPath || !mediaPrepModulePath) throw new Error('approved media-preparation manifest, module and derivative root are required');
  const loader = await import(pathToFileURL(resolve(mediaPrepModulePath)).href);
  const manifest = JSON.parse(await readFile(mediaPrepManifestPath, 'utf8'));
  const prepared = new Map((await loader.validateManifest(manifest, {derivativeRoot, expectedOriginals: loader.expectedOriginalsFromSnapshot(snapshot, 'M')})).map(entry => [entry.sourceId, entry]));
  const sources = snapshot._manifests.M.manifest.sources;
  const root = join(bundleRoot, 'media');
  await mkdir(root, {recursive: true});
  const assets = new Map();
  const selected = new Set(mLayers(snapshot).layers.map(layer => layer.occurrence.sourceId));
  const entries = [];
  for (const source of sources.filter(item => selected.has(item.id))) {
    const derivative = prepared.get(source.id);
    if (source.container === 'heic' && !derivative) throw new Error(`missing approved derivative: ${source.id}`);
    const sourcePath = derivative ? join(derivativeRoot, derivative.path) : join(fixtureRoot, 'M', source.path);
    const expectedHash = derivative ? derivative.sha256 : source.sha256;
    if (await fileHash(sourcePath) !== expectedHash) throw new Error(`staged source hash mismatch: ${source.id}`);
    const sourceExtension = derivative ? extname(derivative.path) : extname(source.path);
    const servedExtension = sourceExtension;
    const relative = `media/${source.id}${servedExtension}`;
    await copyFile(sourcePath, join(bundleRoot, relative));
    if (await fileHash(join(bundleRoot, relative)) !== expectedHash) throw new Error(`copied source hash mismatch: ${source.id}`);
    const element = ['video', 'livePhotoVideo'].includes(source.kind) ? 'video' : 'image';
    assets.set(source.id, {element, path: relative});
    entries.push({bundlePath: relative, originalSha256: source.sha256, preparedSha256: derivative?.sha256 ?? null, servedExtension, sourceId: source.id, sourceExtension});
  }
  return {assets, entries, manifestDigest: manifest.manifestDigest, rawManifestSha256: await fileHash(mediaPrepManifestPath)};
}

export async function buildMPlayerBundle({bundleRoot, derivativeRoot, fixtureRoot, mediaPrepManifestPath, mediaPrepModulePath, runtime}) {
  const snapshot = await freezeSnapshot({acceptedCommit: ACCEPTED_COMMIT, fixtureRoot});
  const model = mLayers(snapshot);
  const root = resolve(bundleRoot);
  await mkdir(root, {recursive: true});
  const [runtimeReceipt, media] = await Promise.all([runtimeFiles(runtime, root), stagedAssets({snapshot, fixtureRoot, derivativeRoot, mediaPrepManifestPath, mediaPrepModulePath, bundleRoot: root})]);
  await writeFile(join(root, 'composition.html'), compositionHtml(model, media.assets));
  await writeFile(join(root, 'verification.json'), json({frameCount: model.frameCount, frames: model.verificationFrames, rate: model.rate, snapshotId: snapshot.snapshotId}));
  await writeFile(join(root, 'index.html'), indexHtml(snapshot.snapshotId, model));
  const receipt = {fixtureId: 'M', frameCount: model.frameCount, rate: model.rate, runtime: runtimeReceipt, snapshotId: snapshot.snapshotId, sourceAssets: media.entries, mediaPreparation: {rawManifestSha256: media.rawManifestSha256, semanticManifestDigest: media.manifestDigest}};
  await writeFile(join(root, 'bundle-manifest.json'), json({...receipt, bundleSemanticDigest: hash(JSON.stringify(stable(receipt)))}));
  return receipt;
}

function options(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) { if (!argv[index]?.startsWith('--') || argv[index + 1] === undefined) throw new Error('invalid player bundle arguments'); result[argv[index].slice(2)] = argv[index + 1]; }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const value = options(process.argv.slice(2));
  const receipt = await buildMPlayerBundle({bundleRoot: value['bundle-root'], derivativeRoot: value['derivative-root'], fixtureRoot: value['fixture-root'], mediaPrepManifestPath: value['media-prep-manifest'], mediaPrepModulePath: value['media-prep-module'], runtime: value.runtime});
  process.stdout.write(`${JSON.stringify(receipt)}\n`);
}
