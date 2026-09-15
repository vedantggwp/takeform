import {frameState} from '../common/index.mjs';

function rationalDifference(left, right) {
  return {num: BigInt(left.ticks) * BigInt(right.timescale) - BigInt(right.ticks) * BigInt(left.timescale), den: BigInt(left.timescale) * BigInt(right.timescale)};
}

function gcd(left, right) {
  let a = left < 0n ? -left : left;
  let b = right < 0n ? -right : right;
  while (b) [a, b] = [b, a % b];
  return a;
}

function reduce(num, den) {
  if (den === 0n) throw new Error('A state-derived rate cannot have a zero denominator');
  const divisor = gcd(num, den);
  return {num: Number(num / divisor), den: Number(den / divisor)};
}

function sameCaption(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function stateLabel(state) {
  return state.authorChapter ?? state.chapterLabel ?? null;
}

function audioKey(role) {
  return `${role.occurrenceId}:${role.role}:${role.layer}`;
}

/**
 * Read-only support for fixture-specific builders.  It deliberately exposes
 * frameState rather than translating the edit into backend timing math.
 */
export function fixtureSupport(snapshot, fixtureId) {
  const fixture = snapshot._manifests[fixtureId];
  if (!fixture) throw new Error(`Unknown fixture ${fixtureId}`);
  const frameCount = fixture.manifest.expected.frameCount;
  return {
    fixtureId,
    frameCount,
    rate: fixture.rate,
    stateAt(frame) {
      if (!Number.isInteger(frame) || frame < 0 || frame >= frameCount) throw new Error(`Frame ${frame} is outside ${fixtureId}`);
      return frameState(snapshot, fixtureId, frame);
    }
  };
}

function sourceRate(first, second, rate) {
  if (!second) return null;
  const sourceDelta = rationalDifference(second.sourceTime, first.sourceTime);
  return reduce(sourceDelta.num * BigInt(rate.num), sourceDelta.den * BigInt(rate.den));
}

function seconds(value) {
  return value.ticks / value.timescale;
}

function recordAudioFrame(runs, latestRunByKey, state, frame, role) {
  const key = audioKey(role);
  const prior = latestRunByKey.get(key);
  if (!prior || prior.endFrame !== frame) {
    const run = {endFrame: frame + 1, first: role, frames: [{frame, gain: role.gain, gainDb: role.gainDb, outputTime: state.outputTime, sourceTime: role.sourceTime}]};
    runs.push(run);
    latestRunByKey.set(key, run);
    return;
  }
  prior.endFrame = frame + 1;
  prior.frames.push({frame, gain: role.gain, gainDb: role.gainDb, outputTime: state.outputTime, sourceTime: role.sourceTime});
}

function sameGain(left, right) {
  return left.gainDb === right.gainDb && left.gain === right.gain;
}

// Keep every change and its preceding hold point. This represents steps and
// linear ramps without filling the producer's 512-point lane with constants.
function compactGainSamples(samples) {
  if (samples.length === 0) return [];
  const points = [samples[0]];
  for (let index = 1; index < samples.length; index += 1) {
    const prior = samples[index - 1];
    const current = samples[index];
    if (sameGain(prior, current)) continue;
    if (points.at(-1) !== prior) points.push(prior);
    points.push(current);
  }
  if (points.at(-1) !== samples.at(-1)) points.push(samples.at(-1));
  return points;
}

function producerTrack(run, rate) {
  const gainSamples = compactGainSamples(run.frames.filter((sample) => sample.gainDb !== undefined || sample.gain !== undefined));
  const first = run.frames[0];
  const usesDbGain = gainSamples.some((sample) => sample.gainDb !== undefined);
  const lane = usesDbGain ? 'fx.hf-gain.gain' : 'volume';
  const points = gainSamples.map((sample) => ({
    t: seconds(sample.outputTime) - seconds(first.outputTime),
    v: usesDbGain ? sample.gainDb : sample.gain
  }));
  return {
    // Preserve rational source identities alongside future markup attributes.
    outputRange: run.first.outputRange,
    sourceRate: sourceRate(run.first, run.frames[1] && {sourceTime: run.frames[1].sourceTime}, rate),
    sourceTime: run.first.sourceTime,
    sourceId: run.first.sourceId,
    ...(points.length > 2 || !sameGain(gainSamples[0] ?? {}, gainSamples.at(-1) ?? {}) ? {
      automation: {version: 1, lanes: [{target: lane, points}]},
      ...(usesDbGain ? {fxChain: {version: 1, nodes: [{id: 'hf-gain', type: 'gain', params: {gain: 0}}]}} : {})
    } : usesDbGain ? {fxChain: {version: 1, nodes: [{id: 'hf-gain', type: 'gain', params: {gain: gainSamples[0]?.gainDb ?? 0}}]}} : {volume: gainSamples[0]?.gain ?? 1})
  };
}

/**
 * T's picture, speech and envelope plan.  Every value is observed from
 * frameState; this module does not compute source offsets, retimes or gains.
 */
export function talkingHeadSupport(snapshot) {
  const support = fixtureSupport(snapshot, 'T');
  const audioRuns = [];
  const latestRunByKey = new Map();
  const captions = [];
  let activeCaptions = null;
  for (let frame = 0; frame < support.frameCount; frame += 1) {
    const state = support.stateAt(frame);
    for (const role of state.audio.roles) {
      recordAudioFrame(audioRuns, latestRunByKey, state, frame, role);
    }
    if (!sameCaption(activeCaptions?.caption ?? null, state.caption)) {
      if (activeCaptions) activeCaptions.endFrame = frame;
      activeCaptions = state.caption ? {caption: state.caption, endFrame: null, startFrame: frame} : null;
      if (activeCaptions) captions.push(activeCaptions);
    }
  }
  if (activeCaptions) activeCaptions.endFrame = support.frameCount;
  const roles = audioRuns.map((run) => {
    const next = run.frames[1];
    return {
      endFrame: run.endFrame,
      gainSamples: run.frames.filter((sample) => sample.gainDb !== undefined),
      occurrenceId: run.first.occurrenceId,
      role: run.first.role,
      sourceId: run.first.sourceId,
      sourceRate: sourceRate(run.first, next && {sourceTime: next.sourceTime}, support.rate),
      sourceTime: run.first.sourceTime,
      startFrame: run.frames[0].frame
    };
  });
  return {
    ...support,
    captions,
    pictureAudioMuted: Array.from({length: support.frameCount}, (_, frame) => support.stateAt(frame).audio.pictureAudio === 'muted').every(Boolean),
    producerAudioTracks: audioRuns.map((run) => producerTrack(run, support.rate)),
    roles
  };
}

/**
 * L's rational-rate, chapter and crossfade evidence.  Crossfade handles are
 * observed together from the shared frame state for both picture and audio.
 */
export function longFilmSupport(snapshot) {
  const support = fixtureSupport(snapshot, 'L');
  const chapters = [];
  const crossfades = [];
  let currentChapter = null;
  let currentCrossfade = null;
  const audioRuns = [];
  const latestRunByKey = new Map();
  for (let frame = 0; frame < support.frameCount; frame += 1) {
    const state = support.stateAt(frame);
    const label = stateLabel(state);
    if (label !== currentChapter?.label) {
      if (currentChapter) currentChapter.endFrame = frame;
      currentChapter = {endFrame: null, label, startFrame: frame};
      chapters.push(currentChapter);
    }
    const pictureSourceIds = state.pictureLayers.map((layer) => layer.sourceId);
    const audioSourceIds = state.audio.roles.map((role) => role.sourceId);
    for (const role of state.audio.roles) {
      recordAudioFrame(audioRuns, latestRunByKey, state, frame, role);
    }
    const multipleHandles = pictureSourceIds.length === 2 && audioSourceIds.length === 2;
    if (multipleHandles) {
      if (!currentCrossfade) currentCrossfade = {audioSourceIds, endFrame: frame + 1, pictureSourceIds, startFrame: frame};
      else currentCrossfade.endFrame = frame + 1;
    } else if (currentCrossfade) {
      crossfades.push(currentCrossfade);
      currentCrossfade = null;
    }
  }
  if (currentChapter) currentChapter.endFrame = support.frameCount;
  if (currentCrossfade) crossfades.push(currentCrossfade);
  return {...support, chapters, crossfades, producerAudioTracks: audioRuns.map((run) => producerTrack(run, support.rate))};
}
