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

test('helper serves the diagnostic document beside its emitted helper resource', async () => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-preview-diagnostic-'));
  const {child, port} = await openHelper(root);
  const response = await fetch(`http://127.0.0.1:${port}/diagnostic.html`);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /takeformPreviewCommand/);
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

test('helper streams closed, open, and suffix byte ranges', async () => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-preview-range-'));
  await writeFile(join(root, 'clip.mp4'), Buffer.from('0123456789'));
  const {child, port} = await openHelper(root);
  const request = range => fetch(`http://127.0.0.1:${port}/bundle/clip.mp4`, {headers: {Range: range}});
  const closed = await request('bytes=2-4');
  assert.equal(closed.status, 206);
  assert.equal(closed.headers.get('content-range'), 'bytes 2-4/10');
  assert.equal(await closed.text(), '234');
  const open = await request('bytes=7-');
  assert.equal(open.status, 206);
  assert.equal(await open.text(), '789');
  const suffix = await request('bytes=-4');
  assert.equal(suffix.status, 206);
  assert.equal(await suffix.text(), '6789');
  for (const range of ['bytes=10-', 'bytes=5-4', 'bytes=-0', 'bytes=0-1,4-5']) {
    const invalid = await request(range);
    assert.equal(invalid.status, 416);
    assert.equal(invalid.headers.get('content-range'), 'bytes */10');
  }
  const head = await fetch(`http://127.0.0.1:${port}/bundle/clip.mp4`, {method: 'HEAD', headers: {Range: 'bytes=1-3'}});
  assert.equal(head.status, 206);
  assert.equal(head.headers.get('content-length'), '3');
  assert.equal((await head.arrayBuffer()).byteLength, 0);
  child.kill('SIGTERM');
  await new Promise(resolve => child.once('exit', resolve));
});

test('helper serves granted MOV assets as video/quicktime with byte ranges', async () => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-preview-mov-'));
  await writeFile(join(root, 'clip.mov'), Buffer.from('0123456789'));
  const {child, port} = await openHelper(root);
  const get = await fetch(`http://127.0.0.1:${port}/bundle/clip.mov`);
  assert.equal(get.status, 200);
  assert.equal(get.headers.get('content-type'), 'video/quicktime');
  assert.equal(await get.text(), '0123456789');
  const range = await fetch(`http://127.0.0.1:${port}/bundle/clip.mov`, {headers: {Range: 'bytes=2-4'}});
  assert.equal(range.status, 206);
  assert.equal(range.headers.get('content-range'), 'bytes 2-4/10');
  assert.equal(await range.text(), '234');
  const head = await fetch(`http://127.0.0.1:${port}/bundle/clip.mov`, {method: 'HEAD', headers: {Range: 'bytes=1-3'}});
  assert.equal(head.status, 206);
  assert.equal(head.headers.get('content-type'), 'video/quicktime');
  assert.equal(head.headers.get('content-length'), '3');
  assert.equal((await head.arrayBuffer()).byteLength, 0);
  child.kill('SIGTERM');
  await new Promise(resolve => child.once('exit', resolve));
});

test('helper rejects a non-Node-22 runtime', {skip: Number(process.versions.node.split('.')[0]) === 22}, async () => {
  const child = spawn(process.execPath, [helper.pathname, '--port', '0'], {stdio: ['ignore', 'pipe', 'pipe']});
  const line = await new Promise(resolve => child.stdout.once('data', data => resolve(String(data))));
  assert.deepEqual(JSON.parse(line), {status: 'error', message: 'Node 22 is required for this comparison host.'});
  assert.equal(await new Promise(resolve => child.once('exit', resolve)), 1);
});
