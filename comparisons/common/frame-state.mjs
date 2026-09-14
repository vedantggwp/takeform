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
      oClip24: [0.17, 0.29, 0.44, 0.45, 5], oClip2997: [0.43, 0.31, 0.44, 0.45, -5], oLiveMatched: [0.21, 0.17, 0.45, 0.48, 2], oLiveMismatch: [0.39, 0.48, 0.42, 0.43, -3]
    }
  },
  T: { pictureAudio: 'muted', caption: { fontFamily: 'system-ui, sans-serif', fontSizePx: 52, lineWrap: 'greedy-two-lines', maxLines: 2, color: '#ffffff', backplate: '#101114', safeMargin: 0.06 }, audio: { musicDbDuringDialogue: -24, musicDbInGaps: -16, attackMs: 120, releaseMs: 350, sfxDb: -18, targetIntegratedLufs: -16, maxTruePeakDbtp: -1 } },
  L: { transitionFrames: 24, pictureOpacity: 'linear', audioCurve: 'equal-power', chapterLabel: 'source-id' }
});

export class ComparisonError extends Error { constructor(message, code = 'comparison-error') { super(message); this.code = code; } }
export const freezeValue = value => deepFreeze(value);
export const freezeTreatment = treatment => deepFreeze(structuredClone(treatment));
export function hydrateFrameState({ snapshotId, manifests, treatment = comparisonTreatment }) {
  if (!snapshotId || !manifests || !treatment) throw new ComparisonError('frame-state input needs a snapshot identity, manifests, and treatment', 'invalid-frame-state-input');
  return deepFreeze({ snapshotId, _manifests: structuredClone(manifests), _treatment: structuredClone(treatment) });
}
const bigint = value => BigInt(value);
export const asRate = rate => { if (!rate || !Number.isInteger(rate.num) || !Number.isInteger(rate.den) || rate.num < 1 || rate.den < 1) throw new ComparisonError('frame rate must contain positive integer num and den', 'invalid-rate'); return rate; };
export const compare = (a, b) => bigint(a.ticks) * bigint(b.timescale) - bigint(b.ticks) * bigint(a.timescale);
export const add = (a, b) => ({ ticks: Number(bigint(a.ticks) * bigint(b.timescale) + bigint(b.ticks) * bigint(a.timescale)), timescale: a.timescale * b.timescale });
const multiply = (a, factor) => ({ ticks: Number(bigint(a.ticks) * bigint(factor.num)), timescale: a.timescale * factor.den });
const outputTime = (frame, rate) => ({ ticks: frame * rate.den, timescale: rate.num });
const active = (time, range) => compare(time, range.start) >= 0 && compare(time, add(range.start, range.duration)) < 0;
const offset = (time, range) => ({ ticks: Number(bigint(time.ticks) * bigint(range.start.timescale) - bigint(range.start.ticks) * bigint(time.timescale)), timescale: time.timescale * range.start.timescale });
const normalize = rect => ({ x: rect[0], y: rect[1], width: rect[2], height: rect[3], rotationDegrees: rect[4] });
const seed = text => [...text].reduce((sum, character) => sum + character.codePointAt(0), 0);

function layerFor(snapshot, fixtureId, occurrence, frame, time) {
  const sourceTime = add(occurrence.sourceRange.start, multiply(offset(time, occurrence.outputRange), occurrence.retimeFactor ?? { num: 1, den: 1 }));
  const layer = { occurrenceId: occurrence.id, sourceId: occurrence.sourceId, role: occurrence.role, sourceRange: occurrence.sourceRange, sourceTime, outputRange: occurrence.outputRange, opacity: 1 };
  if (fixtureId === 'M') {
    const rect = snapshot._treatment.M.panels[occurrence.id];
    if (!rect) throw new ComparisonError(`missing M panel treatment for ${occurrence.id}`, 'missing-treatment');
    const localFrame = frame - Math.ceil(Number(bigint(occurrence.outputRange.start.ticks) * bigint(snapshot._manifests.M.rate.num) / bigint(occurrence.outputRange.start.timescale) / bigint(snapshot._manifests.M.rate.den)));
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

function lTransition(manifest, time) {
  const transition = (manifest.canonicalPlan.occurrences ?? []).find(item => item.role === 'transition' && active(time, item.outputRange));
  if (!transition) return null;
  const next = manifest.canonicalPlan.occurrences[manifest.canonicalPlan.occurrences.findIndex(item => item.id === transition.id) + 1];
  if (!next || !next.id.startsWith('ochapter')) throw new ComparisonError(`transition ${transition.id} lacks an incoming chapter`, 'invalid-transition');
  const midpoint = { ticks: transition.outputRange.start.ticks * 2 + transition.outputRange.duration.ticks, timescale: transition.outputRange.start.timescale * 2 };
  const boundary = (manifest.expected.chapterBoundaries ?? []).find(item => compare(item.outputTime, midpoint) === 0n);
  if (!boundary || boundary.clean) throw new ComparisonError(`transition ${transition.id} lacks its named canonical boundary`, 'invalid-transition');
  const elapsed = offset(time, transition.outputRange);
  const progress = Number(bigint(elapsed.ticks) * bigint(transition.outputRange.duration.timescale)) / Number(bigint(elapsed.timescale) * bigint(transition.outputRange.duration.ticks));
  return { transitionId: transition.id, boundaryIndex: boundary.index, outgoing: { sourceId: transition.sourceId, sourceRange: transition.sourceRange, opacity: 1 - progress }, incoming: { sourceId: next.sourceId, sourceRange: { start: { ticks: 0, timescale: transition.sourceRange.duration.timescale }, duration: transition.sourceRange.duration }, opacity: progress }, audio: { outgoingGain: Math.cos(progress * Math.PI / 2), incomingGain: Math.sin(progress * Math.PI / 2) }, progress };
}

export function frameState(snapshot, fixtureId, frame) {
  const item = snapshot._manifests?.[fixtureId];
  if (!item) throw new ComparisonError(`unknown fixture: ${fixtureId}`, 'unknown-fixture');
  if (!Number.isInteger(frame) || frame < 0 || frame >= item.manifest.expected.frameCount) throw new ComparisonError(`frame ${frame} is outside ${fixtureId}'s accepted range`, 'outside-frame');
  const { manifest, rate } = item; const time = outputTime(frame, rate);
  const activeOccurrences = (manifest.canonicalPlan.occurrences ?? []).filter(occurrence => active(time, occurrence.outputRange));
  let pictureLayers = activeOccurrences.filter(occurrence => occurrence.role === 'picture').map(occurrence => layerFor(snapshot, fixtureId, occurrence, frame, time));
  const state = { fixtureId, frame, rate, outputTime: time, pictureLayers, caption: fixtureId === 'T' ? captionState(snapshot, manifest, time) : null, audio: { roles: [] }, outside: false };
  if (fixtureId === 'T') {
    const dialogue = activeOccurrences.filter(occurrence => occurrence.role === 'dialogue').map(occurrence => layerFor(snapshot, fixtureId, occurrence, frame, time));
    const sfx = activeOccurrences.filter(occurrence => occurrence.role === 'sfx').map(occurrence => layerFor(snapshot, fixtureId, occurrence, frame, time));
    const chapter = [...(manifest.canonicalPlan.authorChapters ?? [])].reverse().find(item => compare(time, item.outputStart) >= 0);
    state.authorChapter = chapter?.label ?? null;
    state.audio = { pictureAudio: 'muted', roles: [...dialogue.map(layer => ({ ...layer, gainDb: 0 })), { role: 'music', gainDb: dialogue.length ? snapshot._treatment.T.audio.musicDbDuringDialogue : snapshot._treatment.T.audio.musicDbInGaps, attackMs: snapshot._treatment.T.audio.attackMs, releaseMs: snapshot._treatment.T.audio.releaseMs }, ...sfx.map(layer => ({ ...layer, gainDb: snapshot._treatment.T.audio.sfxDb }))], normalization: { targetIntegratedLufs: -16, maxTruePeakDbtp: -1, actualBackendMixing: null } };
  }
  if (fixtureId === 'L') {
    const transition = lTransition(manifest, time); const chapter = activeOccurrences.find(occurrence => occurrence.id.startsWith('ochapter'));
    state.chapterLabel = chapter?.sourceId ?? null;
    if (transition) { pictureLayers = [{ ...transition.outgoing, role: 'transition-outgoing' }, { ...transition.incoming, role: 'transition-incoming' }]; state.pictureLayers = pictureLayers; state.audio = { roles: [{ role: 'transition-outgoing', gain: transition.audio.outgoingGain }, { role: 'transition-incoming', gain: transition.audio.incomingGain }], transition }; }
  }
  return state;
}
