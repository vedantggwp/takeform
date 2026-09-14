import assert from 'node:assert/strict';
import {access, chmod, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
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

test('redacts a missing executable path without masking package imports', async (t) => {
  const privateDirectory = await mkdtemp(join(tmpdir(), 'takeform-private-executable-'));
  t.after(() => rm(privateDirectory, {force: true, recursive: true}));
  const result = run('--ffmpeg', join(privateDirectory, 'missing-ffmpeg'));
  assert.equal(result.code, 1);
  assert.equal(result.output.ffmpeg.status, 'error');
  assert.equal(result.output.ffmpeg.error.code, 'ENOENT');
  assert.doesNotMatch(JSON.stringify(result.output), new RegExp(privateDirectory.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.equal(result.output.imports.hyperframes.status, 'ok');
  assert.equal(result.output.imports.remotion.status, 'ok');
});

test('rejects an unsupported Node version before a future adapter runs', () => {
  const result = run('--node-version', 'v21.9.0');
  assert.equal(result.code, 1);
  assert.match(result.output.node.error, /Node 22/);
});

test('validates the exact public bundle API needed before renderMedia', () => {
  const result = run();
  assert.equal(result.code, 0);
  assert.equal(result.output.packages['@remotion/bundler'].version, '4.0.524');
  assert.deepEqual(result.output.imports.remotion.bundlerPublicApis, ['bundle']);
});

test('surfaces a missing runtime import as a doctor error', async (t) => {
  const emptyRuntime = await mkdtemp(join(tmpdir(), 'takeform-empty-runtime-'));
  t.after(() => rm(emptyRuntime, {force: true, recursive: true}));
  const result = run('--runtime', emptyRuntime);
  assert.equal(result.code, 1);
  assert.equal(result.output.imports.hyperframes.status, 'error');
  assert.equal(result.output.imports.hyperframes.error.code, 'ENOENT');
  assert.doesNotMatch(JSON.stringify(result.output), new RegExp(emptyRuntime.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('reports an absent browser before the official bootstrap call', () => {
  const browser = join(tmpdir(), 'takeform-does-not-exist-browser');
  const result = run('--browser', browser, '--bootstrap-browser');
  assert.equal(result.code, 1);
  assert.equal(result.output.browser.remotion.status, 'error');
  assert.equal(result.output.browser.remotion.error.code, 'BROWSER_UNAVAILABLE');
});

test('fails an explicit invalid browser candidate without bootstrap', () => {
  const result = run('--browser', join(tmpdir(), 'takeform-does-not-exist-browser'));
  assert.equal(result.code, 1);
  assert.equal(result.output.browser.candidate.status, 'error');
  assert.equal(result.output.browser.remotion.status, 'not-requested');
});

test('reaps an executable that ignores TERM after bounded grace', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-timeout-child-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const executable = join(directory, 'ignores-term');
  const pidFile = join(directory, 'pid');
  await writeFile(executable, `#!/bin/sh\necho $$ > '${pidFile}'\ntrap '' TERM\nwhile :; do printf x; done\n`);
  await chmod(executable, 0o755);
  const started = Date.now();
  const result = run('--ffmpeg', executable, '--timeout-ms', '500');
  const elapsedMs = Date.now() - started;
  await access(pidFile).catch(() => assert.fail(JSON.stringify(result.output)));
  const pid = Number((await readFile(pidFile, 'utf8')).trim());
  assert.equal(result.code, 1);
  assert.equal(result.output.ffmpeg.error.code, 'TIMEOUT');
  assert.ok(elapsedMs < 2500, `doctor took ${elapsedMs}ms`);
  assert.throws(() => process.kill(pid, 0), {code: 'ESRCH'});
});
