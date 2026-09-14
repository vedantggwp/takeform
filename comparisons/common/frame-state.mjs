export const TREATMENT_VERSION = 'comparison-treatment-v1';

const deepFreeze = value => {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) deepFreeze(child);
    Object.freeze(value);
  }
  return value;
};

export const comparisonTreatment = deepFreeze({
  version: TREATMENT_VERSION,
  M: {
    fit: 'cover', border: { color: '#f4f1ea', width: 0.003 }, entrance: { frames: 12, curve: 'linear' }, drift: { amplitude: 0.006, periodFrames: 180 },
    panels: {
      oHarbor: [0.05, 0.08, 0.43, 0.48, -3], oWorkshop: [0.46, 0.11, 0.46, 0.46, 2], oHill: [0.10, 0.48, 0.42, 0.44, 4], oNight: [0.50, 0.44, 0.43, 0.47, -2],
      oMarket: [0.06, 0.19, 0.45, 0.45, 1], oLibrary: [0.49, 0.20, 0.43, 0.46, -4], oGarden: [0.27, 0.42, 0.45, 0.47, 3], oStation: [0.30, 0.06, 0.37, 0.39, -1],
      oClip24: [0.17, 0.29, 0.44, 0.45, 5], oClip2997: [0.43, 0.31, 0.44, 0.45, -5], oLiveMatched: [0.21, 0.17, 0.45, 0.48, 2], oLiveMismatch: [0.39, 0.48, 0.42, 0.43, -3],
    },
  },
  T: {
    pictureAudio: 'muted',
    caption: { fontFamily: 'system-ui, sans-serif', fontSizePx: 52, lineWrap: 'greedy-two-lines', maxLines: 2, color: '#ffffff', backplate: '#101114', safeMargin: 0.06 },
    audio: { musicDbDuringDialogue: -24, musicDbInGaps: -16, attackMs: 120, releaseMs: 350, gainInterpolation: 'linear-db', sfxDb: -18, targetIntegratedLufs: -16, maxTruePeakDbtp: -1 },
  },
  L: { transitionFrames: 24, pictureOpacity: 'linear', audioCurve: 'equal-power', chapterLabel: 'source-id' },
});

export class ComparisonError extends Error {
  constructor(message, code = 'comparison-error') {
    super(message);
    this.code = code;
  }
}

export const freezeValue = value => deepFreeze(value);
export const freezeTreatment = treatment => deepFreeze(structuredClone(treatment));

const safeBigInt = (value, name) => {
  if (!Number.isSafeInteger(value)) throw new ComparisonError(`${name} must be a safe integer`, 'unsafe-rational');
  return BigInt(value);
};

const gcd = (left, right) => {
  let a = left < 0n ? -left : left;
  let b = right < 0n ? -right : right;
  while (b) [a, b] = [b, a % b];
  return a || 1n;
};

const checkedNumber = (value, name) => {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || BigInt(number) !== value) throw new ComparisonError(`${name} exceeds the safe integer range`, 'unsafe-rational');
  return number;
};

const reduced = (ticks, timescale) => {
  if (timescale === 0n) throw new ComparisonError('rational timescale must be positive', 'invalid-rational');
  const sign = timescale < 0n ? -1n : 1n;
  const numerator = ticks * sign;
  const denominator = timescale * sign;
  const divisor = gcd(numerator, denominator);
  return { ticks: checkedNumber(numerator / divisor, 'rational ticks'), timescale: checkedNumber(denominator / divisor, 'rational timescale') };
};

export const asRational = (value, name = 'rational') => {
  if (!value || typeof value !== 'object') throw new ComparisonError(`${name} must contain ticks and timescale`, 'invalid-rational');
  const timescale = safeBigInt(value.timescale, `${name}.timescale`);
  if (timescale < 1n) throw new ComparisonError(`${name}.timescale must be positive`, 'invalid-rational');
  return reduced(safeBigInt(value.ticks, `${name}.ticks`), timescale);
};

export const asRate = rate => {
  if (!rate || !Number.isSafeInteger(rate.num) || !Number.isSafeInteger(rate.den) || rate.num < 1 || rate.den < 1) throw new ComparisonError('frame rate must contain positive safe integer num and den', 'invalid-rate');
  const value = reduced(BigInt(rate.num), BigInt(rate.den));
  return { num: value.ticks, den: value.timescale };
};

export const compare = (left, right) => {
  const a = asRational(left, 'left rational');
  const b = asRational(right, 'right rational');
  return BigInt(a.ticks) * BigInt(b.timescale) - BigInt(b.ticks) * BigInt(a.timescale);
};

export const add = (left, right) => {
  const a = asRational(left, 'left rational');
  const b = asRational(right, 'right rational');
  return reduced(BigInt(a.ticks) * BigInt(b.timescale) + BigInt(b.ticks) * BigInt(a.timescale), BigInt(a.timescale) * BigInt(b.timescale));
};

export const subtract = (left, right) => {
  const a = asRational(left, 'left rational');
  const b = asRational(right, 'right rational');
  return reduced(BigInt(a.ticks) * BigInt(b.timescale) - BigInt(b.ticks) * BigInt(a.timescale), BigInt(a.timescale) * BigInt(b.timescale));
};

export const multiply = (value, factor) => {
  const rational = asRational(value, 'multiplicand');
  const ratio = asRate(factor);
  return reduced(BigInt(rational.ticks) * BigInt(ratio.num), BigInt(rational.timescale) * BigInt(ratio.den));
};

const outputTime = (frame, rate) => reduced(BigInt(frame) * BigInt(rate.den), BigInt(rate.num));
const active = (time, range) => compare(time, range.start) >= 0n && compare(time, add(range.start, range.duration)) < 0n;
const offset = (time, range) => subtract(time, range.start);
const normalize = rect => ({ x: rect[0], y: rect[1], width: rect[2], height: rect[3], rotationDegrees: rect[4] });
const fullFrame = Object.freeze({ x: 0, y: 0, width: 1, height: 1, rotationDegrees: 0, fit: 'cover' });
const seed = text => [...text].reduce((sum, character) => sum + character.codePointAt(0), 0);
const ratioNumber = (numerator, denominator) => Number(numerator.ticks) * Number(denominator.timescale) / (Number(numerator.timescale) * Number(denominator.ticks));
const clamp = value => Math.min(1, Math.max(0, value));
const lerp = (from, to, progress) => from + (to - from) * clamp(progress);

const ceilFrame = (time, rate) => {
  const value = asRational(time, 'frame time');
  const numerator = BigInt(value.ticks) * BigInt(rate.num);
  const denominator = BigInt(value.timescale) * BigInt(rate.den);
  const frame = numerator >= 0n ? (numerator + denominator - 1n) / denominator : numerator / denominator;
  return checkedNumber(frame, 'frame index');
};

function layerFor(snapshot, fixtureId, occurrence, frame, time) {
  const duration = asRational(occurrence.sourceRange.duration, `${occurrence.id} source duration`);
  const sourceTime = duration.ticks === 0 ? asRational(occurrence.sourceRange.start) : add(occurrence.sourceRange.start, multiply(offset(time, occurrence.outputRange), occurrence.retimeFactor));
  const layer = { occurrenceId: occurrence.id, sourceId: occurrence.sourceId, role: occurrence.role, layer: occurrence.layer, sourceRange: occurrence.sourceRange, sourceTime, outputRange: occurrence.outputRange, opacity: 1, geometry: fullFrame };
  if (fixtureId === 'M') {
    const rect = snapshot._treatment.M.panels[occurrence.id];
    if (!rect) throw new ComparisonError(`missing M panel treatment for ${occurrence.id}`, 'missing-treatment');
    const localFrame = frame - ceilFrame(occurrence.outputRange.start, snapshot._manifests.M.rate);
    const entrance = Math.min(1, Math.max(0, (localFrame + 1) / snapshot._treatment.M.entrance.frames));
    const phase = (seed(occurrence.id) % snapshot._treatment.M.drift.periodFrames + localFrame) / snapshot._treatment.M.drift.periodFrames;
    layer.opacity = entrance;
    layer.geometry = { ...normalize(rect), translateX: Math.sin(phase * Math.PI * 2) * snapshot._treatment.M.drift.amplitude, translateY: Math.cos(phase * Math.PI * 2) * snapshot._treatment.M.drift.amplitude, fit: snapshot._treatment.M.fit, border: snapshot._treatment.M.border };
  }
  return layer;
}

function captionState(snapshot, manifest, time) {
  const activeCaption = (manifest.expected.captions ?? []).find(caption => active(time, caption.outputRange));
  return activeCaption ? { text: activeCaption.text, outputRange: activeCaption.outputRange, occurrenceId: activeCaption.occurrenceId, profile: snapshot._treatment.T.caption } : null;
}

function musicGain(snapshot, time) {
  const treatment = snapshot._treatment.T.audio;
  const ranges = snapshot._manifests.T.speechRanges ?? [];
  if (ranges.find(range => active(time, range))) return { gainDb: treatment.musicDbDuringDialogue, phase: 'speech' };
  let previous = null;
  let next = null;
  for (const range of ranges) {
    const end = add(range.start, range.duration);
    if (compare(end, time) <= 0n) previous = range;
    else if (compare(range.start, time) > 0n) { next = range; break; }
  }
  let releaseGain = treatment.musicDbInGaps;
  let attackGain = treatment.musicDbInGaps;
  let releaseActive = false;
  let attackActive = false;
  if (previous) {
    const releaseStart = add(previous.start, previous.duration);
    const releaseDuration = { ticks: treatment.releaseMs, timescale: 1000 };
    const progress = ratioNumber(subtract(time, releaseStart), releaseDuration);
    if (progress < 1) { releaseActive = true; releaseGain = lerp(treatment.musicDbDuringDialogue, treatment.musicDbInGaps, progress); }
  }
  if (next) {
    const attackDuration = { ticks: treatment.attackMs, timescale: 1000 };
    const attackStart = subtract(next.start, attackDuration);
    if (compare(time, attackStart) >= 0n) { attackActive = true; attackGain = lerp(treatment.musicDbInGaps, treatment.musicDbDuringDialogue, ratioNumber(subtract(time, attackStart), attackDuration)); }
  }
  const phase = releaseActive && attackActive ? 'release-attack' : releaseActive ? 'release' : attackActive ? 'attack' : 'gap';
  return { gainDb: Math.min(releaseGain, attackGain), phase };
}

function lTransition(snapshot, manifest, frame, time) {
  const occurrences = manifest.canonicalPlan.occurrences ?? [];
  const transitionIndex = occurrences.findIndex(item => item.role === 'transition' && active(time, item.outputRange));
  if (transitionIndex < 0) return null;
  const transition = occurrences[transitionIndex];
  const incomingChapter = occurrences[transitionIndex + 1];
  if (!incomingChapter || !incomingChapter.id.startsWith('ochapter')) throw new ComparisonError(`transition ${transition.id} lacks an incoming chapter`, 'invalid-transition');
  const halfDuration = multiply(transition.outputRange.duration, { num: 1, den: 2 });
  const boundaryTime = add(transition.outputRange.start, halfDuration);
  const boundary = (manifest.expected.chapterBoundaries ?? []).find(item => compare(item.outputTime, boundaryTime) === 0n);
  if (!boundary || boundary.clean) throw new ComparisonError(`transition ${transition.id} lacks its named canonical boundary`, 'invalid-transition');
  const elapsed = offset(time, transition.outputRange);
  const progress = clamp(ratioNumber(elapsed, transition.outputRange.duration));
  const incomingHandle = { start: subtract(incomingChapter.sourceRange.start, halfDuration), duration: transition.outputRange.duration };
  const outgoing = { ...layerFor(snapshot, 'L', transition, frame, time), role: 'transition-outgoing', opacity: 1 - progress };
  const incoming = { occurrenceId: incomingChapter.id, sourceId: incomingChapter.sourceId, role: 'transition-incoming', layer: incomingChapter.layer, sourceRange: incomingHandle, sourceTime: add(incomingHandle.start, elapsed), outputRange: transition.outputRange, opacity: progress, geometry: fullFrame };
  return { transitionId: transition.id, boundaryIndex: boundary.index, boundaryTime, outgoing, incoming, audio: { outgoingGain: Math.cos(progress * Math.PI / 2), incomingGain: Math.sin(progress * Math.PI / 2), curve: snapshot._treatment.L.audioCurve }, progress };
}

export function hydrateFrameState({ snapshotId, manifests, treatment = comparisonTreatment }) {
  if (!snapshotId || !manifests || !treatment) throw new ComparisonError('frame-state input needs a snapshot identity, manifests, and treatment', 'invalid-frame-state-input');
  return deepFreeze({ snapshotId, _manifests: structuredClone(manifests), _treatment: structuredClone(treatment) });
}

export function frameState(snapshot, fixtureId, frame) {
  const item = snapshot._manifests?.[fixtureId];
  if (!item) throw new ComparisonError(`unknown fixture: ${fixtureId}`, 'unknown-fixture');
  if (!Number.isSafeInteger(frame) || frame < 0 || frame >= item.manifest.expected.frameCount) throw new ComparisonError(`frame ${frame} is outside ${fixtureId}'s accepted range`, 'outside-frame');
  const rate = asRate(item.rate);
  const manifest = item.manifest;
  const time = outputTime(frame, rate);
  const activeOccurrences = (manifest.canonicalPlan.occurrences ?? []).filter(occurrence => active(time, occurrence.outputRange));
  let pictureLayers = activeOccurrences.filter(occurrence => occurrence.role === 'picture').map(occurrence => layerFor(snapshot, fixtureId, occurrence, frame, time));
  const state = { fixtureId, frame, rate, outputTime: time, pictureLayers, caption: fixtureId === 'T' ? captionState(snapshot, manifest, time) : null, audio: { roles: [] }, outside: false };
  if (fixtureId === 'T') {
    const dialogue = activeOccurrences.filter(occurrence => occurrence.role === 'dialogue').map(occurrence => layerFor(snapshot, fixtureId, occurrence, frame, time));
    const music = activeOccurrences.filter(occurrence => occurrence.role === 'music').map(occurrence => ({ ...layerFor(snapshot, fixtureId, occurrence, frame, time), ...musicGain(snapshot, time), interpolation: snapshot._treatment.T.audio.gainInterpolation, attackMs: snapshot._treatment.T.audio.attackMs, releaseMs: snapshot._treatment.T.audio.releaseMs }));
    const sfx = activeOccurrences.filter(occurrence => occurrence.role === 'sfx').map(occurrence => ({ ...layerFor(snapshot, fixtureId, occurrence, frame, time), gainDb: snapshot._treatment.T.audio.sfxDb }));
    const chapter = [...(manifest.canonicalPlan.authorChapters ?? [])].reverse().find(item => compare(time, item.outputStart) >= 0n);
    state.authorChapter = chapter?.label ?? null;
    state.audio = { pictureAudio: snapshot._treatment.T.pictureAudio, roles: [...dialogue.map(layer => ({ ...layer, gainDb: 0 })), ...music, ...sfx], normalization: { targetIntegratedLufs: snapshot._treatment.T.audio.targetIntegratedLufs, maxTruePeakDbtp: snapshot._treatment.T.audio.maxTruePeakDbtp, actualBackendMixing: null, explicitNormalizationStage: null } };
  }
  if (fixtureId === 'L') {
    const transition = lTransition(snapshot, manifest, frame, time);
    const chapter = activeOccurrences.find(occurrence => occurrence.id.startsWith('ochapter'));
    state.chapterLabel = chapter?.sourceId ?? null;
    if (transition) {
      pictureLayers = [transition.outgoing, transition.incoming];
      state.pictureLayers = pictureLayers;
      state.audio = { roles: [{ ...transition.outgoing, gain: transition.audio.outgoingGain }, { ...transition.incoming, gain: transition.audio.incomingGain }], transition };
    }
  }
  return state;
}
