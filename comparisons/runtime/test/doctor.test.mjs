import assert from 'node:assert/strict';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const runtime = fileURLToPath(new URL('..', import.meta.url));
const doctor = join(runtime, 'doctor.mjs');

function run(...args) {
  const result = spawnSync(process.execPath, [doctor, ...args], {encoding: 'utf8'});
  return {code: result.status, output: JSON.parse(result.stdout)};
}

test('reports a missing FFmpeg executable without masking package imports', () => {
  const result = run('--ffmpeg', join(tmpdir(), 'takeform-does-not-exist'));
  assert.equal(result.code, 1);
  assert.equal(result.output.ffmpeg.status, 'error');
  assert.equal(result.output.imports.hyperframes.status, 'ok');
  assert.equal(result.output.imports.remotion.status, 'ok');
});

test('rejects an unsupported Node version before a future adapter runs', () => {
  const result = run('--node-version', 'v21.9.0');
  assert.equal(result.code, 1);
  assert.match(result.output.node.error, /Node 22/);
});

test('surfaces a missing runtime import as a doctor error', async (t) => {
  const emptyRuntime = await mkdtemp(join(tmpdir(), 'takeform-empty-runtime-'));
  t.after(() => rm(emptyRuntime, {force: true, recursive: true}));
  const result = run('--runtime', emptyRuntime);
  assert.equal(result.code, 1);
  assert.equal(result.output.imports.hyperframes.status, 'error');
  assert.match(result.output.imports.hyperframes.error, /ENOENT/);
});

test('reports an absent browser before the official bootstrap call', () => {
  const browser = join(tmpdir(), 'takeform-does-not-exist-browser');
  const result = run('--browser', browser, '--bootstrap-browser');
  assert.equal(result.code, 1);
  assert.equal(result.output.browser.remotion.status, 'error');
  assert.match(result.output.browser.remotion.error, /could not be queried/);
});
