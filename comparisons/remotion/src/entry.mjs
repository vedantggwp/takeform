import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {TakeformComposition} from './takeform-composition.mjs';

export const compositionMetadata = Object.freeze({
  M: {width: 1920, height: 1080, fps: 30, durationInFrames: 480},
  T: {width: 1920, height: 1080, fps: 30, durationInFrames: 2700},
  L: {width: 1920, height: 1080, fps: 24000 / 1001, durationInFrames: 43157},
});

export const TakeformRoot = () => React.createElement(React.Fragment, null,
  Object.entries(compositionMetadata).map(([fixtureId, metadata]) => React.createElement(Composition, {
    ...metadata,
    id: `takeform-${fixtureId}`,
    key: fixtureId,
    component: TakeformComposition,
    defaultProps: {fixtureId, snapshot: null, origin: '', sourceKinds: {}},
  })),
);

registerRoot(TakeformRoot);
