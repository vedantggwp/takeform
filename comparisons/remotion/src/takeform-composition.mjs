import React from 'react';
import {AbsoluteFill, Audio, Img, OffthreadVideo, Sequence, useCurrentFrame} from 'remotion';
import {frameState} from '../../common/frame-state.mjs';
import {audioAmplitudeAtOutputFrame, mediaPlan} from './media-plan.mjs';

const sourceURL = (origin, sourceId) => `${origin}/asset/${encodeURIComponent(sourceId)}`;

const VisualLayer = ({layer, origin, rate, sourceKinds}) => {
  const geometry = layer.geometry;
  const plan = mediaPlan(layer, rate);
  const style = {position: 'absolute', left: `${geometry.x * 100}%`, top: `${geometry.y * 100}%`, width: `${geometry.width * 100}%`, height: `${geometry.height * 100}%`, opacity: layer.opacity, transform: `rotate(${geometry.rotationDegrees}deg) translate(${(geometry.translateX ?? 0) * 100}%, ${(geometry.translateY ?? 0) * 100}%)`, objectFit: geometry.fit};
  const src = sourceURL(origin, layer.sourceId);
  const child = sourceKinds[layer.sourceId] === 'image'
    ? React.createElement(Img, {src, style})
    : React.createElement(OffthreadVideo, {src, style, muted: true, playbackRate: plan.playbackRate, trimBefore: plan.trimBefore, trimAfter: plan.trimAfter});
  return React.createElement(Sequence, {from: plan.from, durationInFrames: plan.durationInFrames, layout: 'none'}, child);
};

const AudioLayer = ({fixtureId, origin, rate, role, snapshot}) => {
  const plan = mediaPlan(role, rate);
  const volume = frame => audioAmplitudeAtOutputFrame({snapshot, fixtureId, role, rate, frame});
  return React.createElement(Sequence, {from: plan.from, durationInFrames: plan.durationInFrames, layout: 'none'}, React.createElement(Audio, {src: sourceURL(origin, role.sourceId), playbackRate: plan.playbackRate, trimBefore: plan.trimBefore, trimAfter: plan.trimAfter, volume}));
};

export const TakeformComposition = ({snapshot, fixtureId, origin, sourceKinds}) => {
  if (!snapshot) return null;
  const state = frameState(snapshot, fixtureId, useCurrentFrame());
  const rate = state.rate.num / state.rate.den;
  return React.createElement(AbsoluteFill, {style: {background: '#000'}}, [
    ...state.pictureLayers.map(layer => React.createElement(VisualLayer, {key: `${layer.occurrenceId}-${layer.role}`, layer, origin, rate, sourceKinds})),
    ...state.audio.roles.map((role, index) => React.createElement(AudioLayer, {key: `${role.occurrenceId}-${role.role}-${index}`, fixtureId, origin, rate, role, snapshot})),
    state.caption ? React.createElement('div', {key: 'caption', style: {position: 'absolute', bottom: '6%', left: '6%', right: '6%', color: state.caption.profile.color, backgroundColor: state.caption.profile.backplate, fontFamily: state.caption.profile.fontFamily, fontSize: state.caption.profile.fontSizePx, textAlign: 'center'}}, state.caption.text) : null,
  ]);
};
