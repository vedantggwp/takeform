import assert from 'node:assert/strict';
import {mkdtemp, mkdir, symlink, writeFile} from 'node:fs/promises';
import {createServer} from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import test from 'node:test';

const helper = new URL('../Sources/NativePreviewHost/Resources/preview-helper.mjs', import.meta.url);

async function openHelper(root) {
  const child = spawn(process.execPath, [helper.pathname, '--port', '0', '--bundle-root', root], {stdio: ['ignore', 'pipe', 'pipe']});
  const line = await new Promise((resolve, reject) => {
    child.stdout.once('data', data => resolve(String(data)));
    child.once('error', reject);
  });
  return {child, port: JSON.parse(line).port};
}

test('helper serves only granted local assets and shuts down', async () => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-preview-'));
  await mkdir(join(root, 'nested'));
  await writeFile(join(root, 'nested', 'ok.js'), 'export const ok = true;');
  await symlink('/etc/hosts', join(root, 'escape.json'));
  const {child, port} = await openHelper(root);
  const ok = await fetch(`http://127.0.0.1:${port}/bundle/nested/ok.js`);
  assert.equal(ok.status, 200);
  assert.equal((await fetch(`http://127.0.0.1:${port}/bundle/%2e%2e/etc/hosts`)).status, 404);
  assert.equal((await fetch(`http://127.0.0.1:${port}/bundle/escape.json`)).status, 404);
  assert.equal((await fetch(`http://127.0.0.1:${port}/bundle/nested/ok.js`, {method: 'POST'})).status, 405);
  child.kill('SIGTERM');
  await new Promise(resolve => child.once('exit', resolve));
});

test('helper reports an unavailable explicit grant', async () => {
  const missing = join(tmpdir(), `takeform-preview-missing-${Date.now()}`);
  const child = spawn(process.execPath, [helper.pathname, '--port', '0', '--bundle-root', missing], {stdio: ['ignore', 'pipe', 'pipe']});
  const line = await new Promise(resolve => child.stdout.once('data', data => resolve(String(data))));
  assert.deepEqual(JSON.parse(line), {status: 'error', message: 'An explicitly granted local root is unavailable.'});
  assert.equal(await new Promise(resolve => child.once('exit', resolve)), 1);
});

test('helper rejects a non-Node-22 runtime', {skip: Number(process.versions.node.split('.')[0]) === 22}, async () => {
  const child = spawn(process.execPath, [helper.pathname, '--port', '0'], {stdio: ['ignore', 'pipe', 'pipe']});
  const line = await new Promise(resolve => child.stdout.once('data', data => resolve(String(data))));
  assert.deepEqual(JSON.parse(line), {status: 'error', message: 'Node 22 is required for this comparison host.'});
  assert.equal(await new Promise(resolve => child.once('exit', resolve)), 1);
});
