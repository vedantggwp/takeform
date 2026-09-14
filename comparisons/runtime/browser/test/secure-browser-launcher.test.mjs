import assert from 'node:assert/strict';
import {chmod, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {runBounded} from '../runner.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const launcher = join(here, '..', 'secure-browser-launcher.sh');

function start(target, args) {
  return spawn(launcher, args, {env: {...process.env, TAKEFORM_BROWSER_EXECUTABLE: target}});
}

function run(target, args) {
  return new Promise((resolveRun) => {
    const child = start(target, args);
    child.on('close', (code, signal) => resolveRun({code, pid: child.pid, signal}));
  });
}

async function targetFor(t) {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-launcher-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const output = join(directory, 'args');
  const target = join(directory, 'target');
  await writeFile(target, `#!/bin/bash\nprintf '%s\\n' "$@" > '${output}'\n`);
  await chmod(target, 0o755);
  return {directory, output, target};
}

test('filters the pinned Remotion defaults and preserves unrelated arguments', async (t) => {
  const {output, target} = await targetFor(t);
  const result = await run(target, ['--no-sandbox', '--disable-setuid-sandbox', '--allow-running-insecure-content', '--disable-site-isolation-trials', '--disable-features=AudioServiceOutOfProcess,IsolateOrigins,site-per-process,Translate,LocalNetworkAccessChecks,BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights,PrivateNetworkAccessRespectPreflightResults', '--user-data-dir=/tmp/space dir']);
  assert.equal(result.code, 0);
  assert.deepEqual((await readFile(output, 'utf8')).trim().split('\n'), ['--disable-features=AudioServiceOutOfProcess,Translate', '--user-data-dir=/tmp/space dir']);
});

test('filters the pinned HyperFrames defaults and equals spellings', async (t) => {
  const {output, target} = await targetFor(t);
  const result = await run(target, ['--no-sandbox=1', '--disable-setuid-sandbox=true', '--disable-features=AudioServiceOutOfProcess,IsolateOrigins,site-per-process,Translate,BackForwardCache,IntensiveWakeUpThrottling', '--remote-debugging-port=0']);
  assert.equal(result.code, 0);
  assert.deepEqual((await readFile(output, 'utf8')).trim().split('\n'), ['--disable-features=AudioServiceOutOfProcess,Translate,BackForwardCache,IntensiveWakeUpThrottling', '--remote-debugging-port=0']);
});

test('removes an empty filtered feature list', async (t) => {
  const {output, target} = await targetFor(t);
  const result = await run(target, ['--disable-features=IsolateOrigins,site-per-process']);
  assert.equal(result.code, 0);
  assert.equal((await readFile(output, 'utf8')).trim(), '');
});

test('rejects explicit web-security and certificate bypasses before target start', async (t) => {
  const {directory, target} = await targetFor(t);
  const marker = join(directory, 'target-ran');
  await writeFile(target, `#!/bin/bash\ntouch '${marker}'\n`);
  await chmod(target, 0o755);
  for (const argument of ['--disable-web-security=true', '--ignore-certificate-errors=1', '--allow-insecure-localhost']) {
    const result = await run(target, [argument]);
    assert.equal(result.code, 64);
  }
  await assert.rejects(readFile(marker));
});

test('preserves target exit and termination after exec', async (t) => {
  const {directory, target} = await targetFor(t);
  const pidFile = join(directory, 'pid');
  const marker = join(directory, 'term');
  await writeFile(target, `#!/bin/bash\necho $$ > '${pidFile}'\ntrap "echo term > '${marker}'; exit 0" TERM\nwhile :; do sleep 1; done\n`);
  await chmod(target, 0o755);
  const child = start(target, []);
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      assert.equal(Number((await readFile(pidFile, 'utf8')).trim()), child.pid);
      break;
    } catch {
      await delay(10);
    }
  }
  child.kill('SIGTERM');
  const result = await new Promise((resolveClose) => child.on('close', (code, signal) => resolveClose({code, signal})));
  assert.deepEqual(result, {code: 0, signal: null});
  assert.equal((await readFile(marker, 'utf8')).trim(), 'term');
});

test('treats invalid successful output as a protocol failure', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-runner-protocol-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const child = join(directory, 'invalid.mjs');
  await writeFile(child, "process.stdout.write('not-json\\n');\n");
  assert.deepEqual(await runBounded(process.execPath, [child], {timeoutMs: 1000}), {status: 'error', code: 'PROBE_PROTOCOL_ERROR'});
});

test('terminates an owned hanging process group', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-runner-timeout-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const childPidFile = join(directory, 'child-pid');
  const child = join(directory, 'hanging.mjs');
  await writeFile(child, `import {spawn} from 'node:child_process'; import {writeFileSync} from 'node:fs'; const descendant = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {stdio: 'ignore'}); writeFileSync('${childPidFile}', String(descendant.pid)); setInterval(() => {}, 1000);`);
  const result = await runBounded(process.execPath, [child], {timeoutMs: 100});
  assert.deepEqual(result, {status: 'error', code: 'TIMEOUT', cleanup: 'process-group-signalled'});
  const descendantPid = Number((await readFile(childPidFile, 'utf8')).trim());
  await delay(50);
  assert.throws(() => process.kill(descendantPid, 0));
});
