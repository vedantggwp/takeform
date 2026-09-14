import React from 'react';
import {AbsoluteFill, Audio, Img, OffthreadVideo, useCurrentFrame} from 'remotion';
import {frameState} from '../../common/frame-state.mjs';

const amplitude = role => role.gain ?? (role.gainDb === undefined ? 1 : 10 ** (role.gainDb / 20));
const sourceURL = (origin, sourceId) => `${origin}/asset/${encodeURIComponent(sourceId)}`;

const VisualLayer = ({layer, origin, sourceKinds}) => {
  const geometry = layer.geometry;
  const style = {position: 'absolute', left: `${geometry.x * 100}%`, top: `${geometry.y * 100}%`, width: `${geometry.width * 100}%`, height: `${geometry.height * 100}%`, opacity: layer.opacity, transform: `rotate(${geometry.rotationDegrees}deg) translate(${(geometry.translateX ?? 0) * 100}%, ${(geometry.translateY ?? 0) * 100}%)`, objectFit: geometry.fit};
  const src = sourceURL(origin, layer.sourceId);
  return sourceKinds[layer.sourceId] === 'image' ? React.createElement(Img, {src, style}) : React.createElement(OffthreadVideo, {src, style, volume: 0});
};

export const TakeformComposition = ({snapshot, fixtureId, origin, sourceKinds}) => {
  const state = frameState(snapshot, fixtureId, useCurrentFrame());
  return React.createElement(AbsoluteFill, {style: {background: '#000'}}, [
    ...state.pictureLayers.map(layer => React.createElement(VisualLayer, {key: `${layer.occurrenceId}-${layer.role}`, layer, origin, sourceKinds})),
    ...state.audio.roles.map((role, index) => React.createElement(Audio, {key: `${role.occurrenceId}-${index}`, src: sourceURL(origin, role.sourceId), volume: amplitude(role)})),
    state.caption ? React.createElement('div', {key: 'caption', style: {position: 'absolute', bottom: '6%', left: '6%', right: '6%', color: state.caption.profile.color, backgroundColor: state.caption.profile.backplate, fontFamily: state.caption.profile.fontFamily, fontSize: state.caption.profile.fontSizePx, textAlign: 'center'}}, state.caption.text) : null,
  ]);
};
