#!/usr/bin/env node
import { statfs } from 'node:fs/promises';
import { cleanupAttemptScratch, comparisonTreatment, createAttempt, finishAttempt, frameState, freezeSnapshot, reserveStorage } from './index.mjs';

const [command, ...rest] = process.argv.slice(2);
const option = name => { const index = rest.indexOf(name); return index < 0 ? undefined : rest[index + 1]; };
const required = name => { const value = option(name); if (!value) throw new Error(`missing ${name}`); return value; };
const emit = value => process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
const root = () => required('--fixture-root');
const commit = () => required('--accepted-commit');
const integer = name => { const value = Number(required(name)); if (!Number.isSafeInteger(value)) throw new Error(`${name} must be a safe integer`); return value; };

try {
  if (command === 'freeze' || command === 'validate') {
    const started = performance.now(); const snapshot = await freezeSnapshot({ fixtureRoot: root(), acceptedCommit: commit(), treatment: comparisonTreatment });
    emit({ command, elapsedMs: performance.now() - started, validationOverheadOnly: true, snapshot: { ...snapshot, _manifests: undefined } });
  } else if (command === 'inspect') {
    const snapshot = await freezeSnapshot({ fixtureRoot: root(), acceptedCommit: commit() }); emit(frameState(snapshot, required('--fixture'), Number(required('--frame'))));
  } else if (command === 'boundary') {
    const snapshot = await freezeSnapshot({ fixtureRoot: root(), acceptedCommit: commit() }); const fixture = required('--fixture'); const frame = Number(required('--frame')); emit({ before: frameState(snapshot, fixture, frame - 1), at: frameState(snapshot, fixture, frame) });
  } else if (command === 'reserve') {
    const snapshot = await freezeSnapshot({ fixtureRoot: root(), acceptedCommit: commit() }); const manifest = snapshot._manifests[required('--fixture')].manifest; const probe = await statfs(option('--path') ?? process.cwd()); const freeBytes = option('--free-bytes') ? integer('--free-bytes') : Number(probe.bavail) * Number(probe.bsize); const route = required('--route'); emit(reserveStorage({ route, width: manifest.canonicalPlan.width, height: manifest.canonicalPlan.height, frameCount: manifest.expected.frameCount, scale: Number(option('--scale') ?? 1), expectedOutputBytes: integer('--expected-output-bytes'), decodeCacheBytes: route === 'streaming' ? integer('--decode-cache-bytes') : undefined, pipelineBufferBytes: route === 'streaming' ? integer('--pipeline-buffer-bytes') : undefined, runtimeFreeFloorBytes: route === 'streaming' ? integer('--runtime-floor-bytes') : undefined, freeBytes }));
  } else if (command === 'attempt') {
    if (required('--backend') !== 'fake' || option('--output')) throw new Error('attempt command is fake lifecycle only and cannot declare renderer output');
    const attempt = createAttempt({ id: required('--id'), snapshotId: required('--snapshot-id'), backend: { kind: 'fake', identity: 'fake', version: 'lifecycle-only' }, attemptRoot: required('--attempt-root'), scratchPaths: required('--path').split(',') });
    const terminal = await finishAttempt(attempt, { status: required('--status') });
    emit(option('--cleanup') === 'true' ? { attempt: terminal, cleanup: await cleanupAttemptScratch(terminal) } : terminal);
  } else throw new Error('commands: validate, freeze, inspect, boundary, reserve, attempt');
} catch (error) { process.stderr.write(`${error.code ?? 'error'}: ${error.message}\n`); process.exitCode = 1; }
