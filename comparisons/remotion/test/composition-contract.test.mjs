import assert from 'node:assert/strict';
import test from 'node:test';
import {freezeSnapshot, frameState} from '../../common/index.mjs';
import {audioAmplitudeAtFrame, audioAmplitudeAtOutputFrame, mediaPlan} from '../src/media-plan.mjs';
import {compositionProps} from '../render-attempt.mjs';

const fixtureRoot = process.env.TAKEFORM_FIXTURE_ROOT;
const acceptedCommit = '8a3daf1978093a3d67649b8f3779a9aa15fab876';
const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} !== ${expected}`);

let snapshot;
test.before(async () => {
  if (!fixtureRoot) throw new Error('set TAKEFORM_FIXTURE_ROOT to the local accepted fixture root');
  snapshot = await freezeSnapshot({fixtureRoot, acceptedCommit});
});

test('maps nonzero source offsets and retimes through public media trim units', () => {
  const manifest = snapshot._manifests.T.manifest;
  const occurrence = manifest.canonicalPlan.occurrences.find(item => item.role === 'picture' && item.sourceRange.start.ticks > 0 && item.retimeFactor.num !== item.retimeFactor.den);
  assert.ok(occurrence, 'T needs a retimed picture occurrence with a nonzero source offset');
  const state = frameState(snapshot, 'T', 0);
  const rate = state.rate.num / state.rate.den;
  const plan = mediaPlan(occurrence, rate);
  assert.ok(plan.trimBefore > 0);
  assert.notEqual(plan.playbackRate, 1);
  close((plan.trimBefore * plan.playbackRate) / rate, occurrence.sourceRange.start.ticks / occurrence.sourceRange.start.timescale);
  close((plan.trimAfter * plan.playbackRate) / rate, (occurrence.sourceRange.start.ticks / occurrence.sourceRange.start.timescale) + (occurrence.sourceRange.duration.ticks / occurrence.sourceRange.duration.timescale));
});

test('uses frame state gain envelopes for every L crossfade audio role', () => {
  const manifest = snapshot._manifests.L.manifest;
  const rate = snapshot._manifests.L.rate.num / snapshot._manifests.L.rate.den;
  const transitions = manifest.canonicalPlan.occurrences.filter(item => item.role === 'transition');
  assert.equal(transitions.length, 14);
  for (const transition of transitions) {
    const frame = Math.ceil((transition.outputRange.start.ticks / transition.outputRange.start.timescale) * rate);
    const state = frameState(snapshot, 'L', frame);
    assert.equal(state.audio.transition.transitionId, transition.id);
    assert.equal(state.audio.roles.length, 2);
    for (const role of state.audio.roles) {
      const plan = mediaPlan(role, rate);
      assert.ok(plan.durationInFrames > 0);
      close(audioAmplitudeAtFrame({snapshot, fixtureId: 'L', role, frame}), role.gain);
      close(audioAmplitudeAtOutputFrame({snapshot, fixtureId: 'L', role, rate, frame: frame - plan.from}), role.gain);
    }
  }
});

test('maps a retimed dialogue source offset through the audio trim plan', () => {
  const state = frameState(snapshot, 'T', 361);
  const role = state.audio.roles.find(item => item.occurrenceId === 'oDlg2A');
  assert.ok(role);
  const rate = state.rate.num / state.rate.den;
  const plan = mediaPlan(role, rate);
  assert.ok(plan.trimBefore > 0);
  assert.notEqual(plan.playbackRate, 1);
  close((plan.trimBefore * plan.playbackRate) / rate, role.sourceRange.start.ticks / role.sourceRange.start.timescale);
  close((plan.trimAfter * plan.playbackRate) / rate, (role.sourceRange.start.ticks + role.sourceRange.duration.ticks) / role.sourceRange.start.timescale);
  assert.equal(audioAmplitudeAtOutputFrame({snapshot, fixtureId: 'T', role, rate, frame: 1}), 1);
});

test('keeps a gain-one chapter bed outside L crossfades', () => {
  const state = frameState(snapshot, 'L', 0);
  assert.equal(state.audio.transition, undefined);
  assert.equal(state.audio.roles.length, 1);
  assert.equal(audioAmplitudeAtFrame({snapshot, fixtureId: 'L', role: state.audio.roles[0], frame: 0}), 1);
});

test('derives selected source kinds from the frozen snapshot', () => {
  const props = compositionProps({snapshot, fixtureId: 'M', origin: 'http://127.0.0.1:1'});
  assert.equal(props.sourceKinds.harbor, 'image');
  assert.equal(props.sourceKinds.clip24, 'media');
  assert.equal(props.sourceKinds.harborCorrupt, undefined);
});
