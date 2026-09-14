#!/usr/bin/env node
import { statfs } from 'node:fs/promises';
import { comparisonTreatment, createAttempt, finishAttempt, frameState, freezeSnapshot, reserveStorage } from './index.mjs';

const [command, ...rest] = process.argv.slice(2);
const option = name => { const index = rest.indexOf(name); return index < 0 ? undefined : rest[index + 1]; };
const required = name => { const value = option(name); if (!value) throw new Error(`missing ${name}`); return value; };
const emit = value => process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
const root = () => required('--fixture-root');
const commit = () => required('--accepted-commit');

try {
  if (command === 'freeze' || command === 'validate') {
    const started = performance.now(); const snapshot = await freezeSnapshot({ fixtureRoot: root(), acceptedCommit: commit(), treatment: comparisonTreatment });
    emit({ command, elapsedMs: performance.now() - started, validationOverheadOnly: true, snapshot: { ...snapshot, _manifests: undefined } });
  } else if (command === 'inspect') {
    const snapshot = await freezeSnapshot({ fixtureRoot: root(), acceptedCommit: commit() }); emit(frameState(snapshot, required('--fixture'), Number(required('--frame'))));
  } else if (command === 'boundary') {
    const snapshot = await freezeSnapshot({ fixtureRoot: root(), acceptedCommit: commit() }); const fixture = required('--fixture'); const frame = Number(required('--frame')); emit({ before: frameState(snapshot, fixture, frame - 1), at: frameState(snapshot, fixture, frame) });
  } else if (command === 'reserve') {
    const snapshot = await freezeSnapshot({ fixtureRoot: root(), acceptedCommit: commit() }); const manifest = snapshot._manifests[required('--fixture')].manifest; const probe = await statfs(option('--path') ?? process.cwd()); const freeBytes = option('--free-bytes') ? Number(option('--free-bytes')) : Number(probe.bavail) * Number(probe.bsize); emit(reserveStorage({ route: required('--route'), width: manifest.canonicalPlan.width, height: manifest.canonicalPlan.height, frameCount: manifest.expected.frameCount, scale: Number(option('--scale') ?? 1), expectedOutputBytes: Number(option('--expected-output-bytes') ?? 0), decodeCacheBytes: Number(option('--decode-cache-bytes') ?? 0), pipelineBufferBytes: Number(option('--pipeline-buffer-bytes') ?? 0), runtimeFreeFloorBytes: Number(option('--runtime-floor-bytes') ?? 1073741824), freeBytes }));
  } else if (command === 'attempt') {
    const attempt = createAttempt({ id: required('--id'), snapshotId: required('--snapshot-id'), backend: required('--backend'), declaredPaths: required('--path').split(',') }); const status = required('--status'); emit(finishAttempt(attempt, { status, terminalInventory: attempt.declaredPaths.map(path => ({ path, exists: false })), outputReceipt: status === 'completed' ? { status: 'completed', path: required('--output') } : null }));
  } else throw new Error('commands: validate, freeze, inspect, boundary, reserve, attempt');
} catch (error) { process.stderr.write(`${error.code ?? 'error'}: ${error.message}\n`); process.exitCode = 1; }
