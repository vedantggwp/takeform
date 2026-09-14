import assert from 'node:assert/strict';
import {chmod, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';

const here = dirname(fileURLToPath(import.meta.url));
const launcher = join(here, '..', 'secure-browser-launcher.sh');

function run(target, args) {
  return new Promise((resolveRun) => {
    const child = start(target, args);
    child.on('close', (code, signal) => resolveRun({code, pid: child.pid, signal}));
  });
}

function start(target, args) {
  return spawn(launcher, args, {env: {...process.env, TAKEFORM_BROWSER_EXECUTABLE: target}});
}

async function waitForFile(path) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      return await readFile(path, 'utf8');
    } catch {
      await delay(10);
    }
  }
  throw new Error('Target did not start');
}

test('removes only the upstream sandbox defaults and preserves spaced arguments', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-launcher-args-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const output = join(directory, 'args');
  const target = join(directory, 'target');
  await writeFile(target, `#!/bin/bash\nprintf '%s\\n' "$@" > '${output}'\n`);
  await chmod(target, 0o755);
  const result = await run(target, ['--no-sandbox', '--disable-setuid-sandbox', '--user-data-dir=/tmp/space dir', '--remote-debugging-port=0']);
  assert.equal(result.code, 0);
  assert.deepEqual((await readFile(output, 'utf8')).trim().split('\n'), ['--user-data-dir=/tmp/space dir', '--remote-debugging-port=0']);
});

test('rejects a web-security override before the target starts', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-launcher-reject-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const marker = join(directory, 'target-ran');
  const target = join(directory, 'target');
  await writeFile(target, `#!/bin/bash\ntouch '${marker}'\n`);
  await chmod(target, 0o755);
  const result = await run(target, ['--disable-web-security']);
  assert.equal(result.code, 64);
  await assert.rejects(readFile(marker));
});

test('rejects a security-sensitive disable-features bundle', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-launcher-features-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const target = join(directory, 'target');
  await writeFile(target, '#!/bin/bash\nexit 0\n');
  await chmod(target, 0o755);
  const result = await run(target, ['--disable-features=Translate,LocalNetworkAccessChecks,BlockInsecurePrivateNetworkRequests']);
  assert.equal(result.code, 64);
});

test('replaces the wrapper process so target exit is preserved', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-launcher-exec-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const pidFile = join(directory, 'pid');
  const target = join(directory, 'target');
  await writeFile(target, `#!/bin/bash\necho $$ > '${pidFile}'\nexit 0\n`);
  await chmod(target, 0o755);
  const launched = run(target, []);
  const result = await launched;
  assert.equal(result.code, 0);
  const targetPid = Number((await readFile(pidFile, 'utf8')).trim());
  assert.equal(result.pid, targetPid);
});

test('delivers termination to the exec target', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'takeform-launcher-signal-'));
  t.after(() => rm(directory, {force: true, recursive: true}));
  const pidFile = join(directory, 'pid');
  const marker = join(directory, 'term');
  const target = join(directory, 'target');
  await writeFile(target, `#!/bin/bash\necho $$ > '${pidFile}'\ntrap "echo term > '${marker}'; exit 0" TERM\nwhile :; do sleep 1; done\n`);
  await chmod(target, 0o755);
  const child = start(target, []);
  const targetPid = Number((await waitForFile(pidFile)).trim());
  assert.equal(child.pid, targetPid);
  child.kill('SIGTERM');
  const result = await new Promise((resolveClose) => child.on('close', (code, signal) => resolveClose({code, signal})));
  assert.deepEqual(result, {code: 0, signal: null});
  assert.equal((await readFile(marker, 'utf8')).trim(), 'term');
});
