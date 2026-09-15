import {createHash} from 'node:crypto';
import {mkdir, symlink, writeFile} from 'node:fs/promises';
import {basename, join, resolve} from 'node:path';
import {frameState} from '../common/index.mjs';
import {longFilmSupport, talkingHeadSupport} from './fixture-support.mjs';

function seconds(value) {
  return value.ticks / value.timescale;
}

function rateBetween(first, second, rate) {
  if (!second) return {num: 1, den: 1};
  const numerator = (BigInt(second.ticks) * BigInt(first.timescale) - BigInt(first.ticks) * BigInt(second.timescale)) * BigInt(rate.num);
  const denominator = BigInt(first.timescale) * BigInt(second.timescale) * BigInt(rate.den);
  let a = numerator < 0n ? -numerator : numerator;
  let b = denominator < 0n ? -denominator : denominator;
  while (b) [a, b] = [b, a % b];
  return {num: Number(numerator / a), den: Number(denominator / a)};
}

function html(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

function identifier(value) {
  return String(value).replaceAll(/[^A-Za-z0-9_-]/g, '-');
}

function elementKind(source) {
  return ['video', 'livePhotoVideo'].includes(source.kind) ? 'video' : 'image';
}

function styleValue(layer) {
  return {
    geometry: layer.geometry,
    opacity: layer.opacity
  };
}

function sameStyle(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function visualRuns(snapshot, fixtureId) {
  const fixture = snapshot._manifests[fixtureId];
  const active = new Map();
  const runs = [];
  for (let frame = 0; frame < fixture.manifest.expected.frameCount; frame += 1) {
    const state = frameState(snapshot, fixtureId, frame);
    for (const layer of state.pictureLayers) {
      const key = `${layer.occurrenceId}:${layer.sourceId}:${layer.role}:${layer.layer}`;
      let run = active.get(key);
      if (!run || run.endFrame !== frame) {
        run = {
          endFrame: frame + 1,
          firstSourceTime: layer.sourceTime,
          id: `picture-${identifier(key)}-${runs.length}`,
          outputRange: layer.outputRange,
          sourceId: layer.sourceId,
          startFrame: frame,
          styleSamples: [{frame, value: styleValue(layer)}]
        };
        runs.push(run);
        active.set(key, run);
      } else {
        run.endFrame = frame + 1;
        if (!run.secondSourceTime) run.secondSourceTime = layer.sourceTime;
        const previous = run.styleSamples.at(-1).value;
        const current = styleValue(layer);
        if (!sameStyle(previous, current)) run.styleSamples.push({frame, value: current});
      }
    }
  }
  return runs.map((run) => ({
    ...run,
    sourceRate: rateBetween(run.firstSourceTime, run.secondSourceTime, fixture.rate)
  }));
}

function captions(snapshot) {
  return talkingHeadSupport(snapshot).captions.map((caption, index) => ({
    ...caption,
    id: `caption-${index}`
  }));
}

function chapters(snapshot) {
  return longFilmSupport(snapshot).chapters.map((chapter, index) => ({
    ...chapter,
    id: `chapter-${index}`
  }));
}

function audioTracks(snapshot, fixtureId) {
  return fixtureId === 'T' ? talkingHeadSupport(snapshot).producerAudioTracks : longFilmSupport(snapshot).producerAudioTracks;
}

export function tlPayload(snapshot, fixtureId, prepared = new Map()) {
  if (!['T', 'L'].includes(fixtureId)) throw new Error(`T/L composition does not support ${fixtureId}`);
  const fixture = snapshot._manifests[fixtureId];
  const visuals = visualRuns(snapshot, fixtureId);
  const tracks = audioTracks(snapshot, fixtureId);
  const selected = new Set([
    ...visuals.map((visual) => visual.sourceId),
    ...tracks.map((track) => track.sourceId)
  ]);
  const sources = Object.fromEntries(fixture.manifest.sources.filter((source) => selected.has(source.id)).map((source) => {
    const path = prepared.get(source.id)?.path ?? source.path;
    return [source.id, {element: elementKind(source), id: source.id, path: `media/${source.id}${path.slice(path.lastIndexOf('.'))}`}];
  }));
  if (Object.keys(sources).length !== selected.size) throw new Error(`Selected ${fixtureId} media is absent from its frozen manifest`);
  return {
    captions: fixtureId === 'T' ? captions(snapshot) : [],
    chapters: fixtureId === 'L' ? chapters(snapshot) : [],
    durationSeconds: seconds(fixture.manifest.expected.outputDuration),
    fixtureId,
    frameCount: fixture.manifest.expected.frameCount,
    height: fixture.manifest.canonicalPlan.height,
    rate: fixture.rate,
    sources,
    tracks,
    visuals,
    width: fixture.manifest.canonicalPlan.width
  };
}

function timingAttributes(range, sourceTime, sourceRate) {
  const start = seconds(range.start);
  const duration = seconds(range.duration);
  return `data-start="${start}" data-duration="${duration}" data-end="${start + duration}" data-media-start="${seconds(sourceTime)}" data-playback-rate="${sourceRate.num / sourceRate.den}"`;
}

function visualMarkup(payload, visual) {
  const source = payload.sources[visual.sourceId];
  const attrs = timingAttributes(visual.outputRange, visual.firstSourceTime, visual.sourceRate);
  if (source.element === 'image') return `<img id="${html(visual.id)}" src="${html(source.path)}" ${attrs} alt="" />`;
  return `<video id="${html(visual.id)}" src="${html(source.path)}" ${attrs} data-has-audio="false" muted playsinline preload="auto"></video>`;
}

function audioMarkup(payload, track) {
  const source = payload.sources[track.sourceId];
  const sourceRate = track.sourceRate ?? {num: 1, den: 1};
  const attrs = timingAttributes(track.outputRange, track.sourceTime, sourceRate);
  const automation = track.automation ? ` data-automation="${html(JSON.stringify(track.automation))}"` : '';
  const fxChain = track.fxChain ? ` data-fx-chain="${html(JSON.stringify(track.fxChain))}"` : '';
  const volume = track.volume === undefined ? '' : ` data-volume="${track.volume}"`;
  return `<audio id="${html(track.id)}" src="${html(source.path)}" ${attrs}${automation}${fxChain}${volume}></audio>`;
}

const browserModule = String.raw`const state = await fetch('./state.json').then((response) => response.json());
const pictures = new Map(state.visuals.map((visual) => [visual.id, document.getElementById(visual.id)]));
const captions = new Map(state.captions.map((caption) => [caption.id, document.getElementById(caption.id)]));
const chapters = new Map(state.chapters.map((chapter) => [chapter.id, document.getElementById(chapter.id)]));
function seconds(value) { return value.ticks / value.timescale; }
function sample(samples, frame) { let result = samples[0].value; for (const item of samples) { if (item.frame > frame) break; result = item.value; } return result; }
function style(node, value) {
  const geometry = value.geometry;
  node.style.left = (geometry.x * 100) + '%';
  node.style.top = (geometry.y * 100) + '%';
  node.style.width = (geometry.width * 100) + '%';
  node.style.height = (geometry.height * 100) + '%';
  node.style.opacity = String(value.opacity);
  node.style.transform = 'translate(' + ((geometry.translateX ?? 0) * 100) + '%, ' + ((geometry.translateY ?? 0) * 100) + '%) rotate(' + geometry.rotationDegrees + 'deg)';
  node.style.objectFit = geometry.fit;
}
let pending = Promise.resolve();
function seek(time) {
  const frame = Math.max(0, Math.min(state.frameCount - 1, Math.round(time * state.rate.num / state.rate.den)));
  const waits = [];
  for (const visual of state.visuals) {
    const node = pictures.get(visual.id);
    const active = frame >= visual.startFrame && frame < visual.endFrame;
    node.style.display = active ? 'block' : 'none';
    if (!active) continue;
    style(node, sample(visual.styleSamples, frame));
    if (node instanceof HTMLVideoElement) {
      const sourceTime = seconds(visual.firstSourceTime) + (frame - visual.startFrame) * state.rate.den / state.rate.num * visual.sourceRate.num / visual.sourceRate.den;
      if (Math.abs(node.currentTime - sourceTime) > 0.002) waits.push(new Promise((resolveSeek) => { node.onseeked = () => resolveSeek(); node.currentTime = sourceTime; }));
    }
  }
  for (const caption of state.captions) captions.get(caption.id).style.display = frame >= caption.startFrame && frame < caption.endFrame ? 'block' : 'none';
  for (const chapter of state.chapters) chapters.get(chapter.id).style.display = frame >= chapter.startFrame && frame < chapter.endFrame ? 'block' : 'none';
  pending = Promise.all(waits);
  return pending;
}
window.__hf = {duration: state.durationSeconds, seek};
window.__hfWaitForSeekCompletion = () => pending;
seek(0);`;

function page(payload) {
  const visuals = payload.visuals.map((visual) => visualMarkup(payload, visual)).join('');
  const tracks = payload.tracks.map((track) => audioMarkup(payload, track)).join('');
  const captions = payload.captions.map((caption) => `<div id="${caption.id}" class="caption">${html(caption.caption.text)}</div>`).join('');
  const chapters = payload.chapters.map((chapter) => `<div id="${chapter.id}" class="chapter" aria-label="${html(chapter.label)}">${html(chapter.label)}</div>`).join('');
  return `<!doctype html><html><head><meta charset="utf-8"><style>html,body,#root{margin:0;width:100%;height:100%;overflow:hidden;background:#101114}#root{position:relative;color:#f4f1ea;font-family:system-ui,sans-serif}video,img{position:absolute;box-sizing:border-box}.caption,.chapter{display:none;position:absolute;z-index:99;text-shadow:0 2px 4px #000}.caption{left:8%;right:8%;bottom:8%;font-size:42px;text-align:center}.chapter{left:4%;top:4%;font-size:26px}</style></head><body><main id="root" data-composition-id="takeform-${payload.fixtureId}" data-width="${payload.width}" data-height="${payload.height}" data-duration="${payload.durationSeconds}" data-no-timeline data-probe-marker="hyperframes-${payload.fixtureId.toLowerCase()}">${visuals}${tracks}${captions}${chapters}</main><script type="module" src="./composition.mjs"></script></body></html>`;
}

export async function writeTlProject(snapshot, fixtureId, fixtureRoot, project, prepared, derivativeRoot) {
  const payload = tlPayload(snapshot, fixtureId, prepared);
  const fixtureDirectory = join(fixtureRoot, fixtureId);
  const media = join(project, 'media');
  await mkdir(media, {recursive: true});
  for (const source of snapshot._manifests[fixtureId].manifest.sources.filter((candidate) => candidate.id in payload.sources)) {
    const entry = prepared.get(source.id);
    await symlink(entry ? resolve(derivativeRoot, entry.path) : resolve(fixtureDirectory, source.path), join(media, basename(payload.sources[source.id].path)));
  }
  await writeFile(join(project, 'state.json'), JSON.stringify(payload));
  await writeFile(join(project, 'composition.mjs'), browserModule);
  await writeFile(join(project, 'index.html'), page(payload));
  return createHash('sha256').update(JSON.stringify(payload)).digest('hex');
}
