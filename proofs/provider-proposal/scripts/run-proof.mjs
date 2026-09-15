import {performance} from 'node:perf_hooks';
import {spawn} from 'node:child_process';

const started = performance.now();
const child = spawn(process.execPath, ['--test', 'test/proposal.test.mjs'], {cwd: new URL('..', import.meta.url), stdio: 'inherit'});
child.once('exit', (code) => {
  const elapsedMs = Math.round((performance.now() - started) * 100) / 100;
  console.log(JSON.stringify({proof: 'provider-proposal', node: process.version, elapsedMs, exitCode: code}));
  process.exitCode = code ?? 1;
});
