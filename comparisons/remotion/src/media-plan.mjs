import {frameState} from '../../common/frame-state.mjs';

const seconds = value => value.ticks / value.timescale;
const frameCount = (value, rate) => seconds(value) * rate;

export const mediaPlan = (layer, rate) => {
  const durationInFrames = frameCount(layer.outputRange.duration, rate);
  const playbackRate = seconds(layer.sourceRange.duration) / seconds(layer.outputRange.duration);
  const trimBefore = frameCount(layer.sourceRange.start, rate) / playbackRate;
  return Object.freeze({from: frameCount(layer.outputRange.start, rate), durationInFrames, playbackRate, trimBefore, trimAfter: trimBefore + durationInFrames});
};

const amplitude = role => role.gain ?? (role.gainDb === undefined ? 1 : 10 ** (role.gainDb / 20));

export const audioAmplitudeAtFrame = ({snapshot, fixtureId, role, frame}) => {
  const active = frameState(snapshot, fixtureId, frame).audio.roles.find(candidate => candidate.occurrenceId === role.occurrenceId && candidate.role === role.role && candidate.sourceId === role.sourceId);
  return active ? amplitude(active) : 0;
};

export const audioAmplitudeAtOutputFrame = ({snapshot, fixtureId, role, rate, frame}) => audioAmplitudeAtFrame({snapshot, fixtureId, role, frame: mediaPlan(role, rate).from + frame});
