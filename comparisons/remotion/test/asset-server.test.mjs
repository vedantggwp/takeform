import assert from 'node:assert/strict';
import {mkdtemp, mkdir, symlink, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {startAssetServer} from '../asset-server.mjs';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'takeform-remotion-assets-'));
  await mkdir(join(root, 'M', 'media'), {recursive: true});
  await writeFile(join(root, 'M', 'media', 'harbor.png'), '0123456789');
  return root;
}

const snapshot = {sources: [{fixtureId: 'M', sourceId: 'harbor', status: 'selected', path: 'M/media/harbor.png'}]};

test('serves an explicit source with byte ranges and no fixture copy', async t => {
  const root = await fixture();
  const server = await startAssetServer({fixtureRoot: root, snapshot, fixtureId: 'M'});
  t.after(() => server.close());
  const partial = await fetch(server.assetURL('harbor'), {headers: {Range: 'bytes=2-5'}});
  assert.equal(partial.status, 206);
  assert.equal(partial.headers.get('content-range'), 'bytes 2-5/10');
  assert.equal(await partial.text(), '2345');
  const head = await fetch(server.assetURL('harbor'), {method: 'HEAD'});
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('accept-ranges'), 'bytes');
});

test('rejects traversal, unknown source, unsupported method, and symlink grant', async t => {
  const root = await fixture();
  const server = await startAssetServer({fixtureRoot: root, snapshot, fixtureId: 'M'});
  t.after(() => server.close());
  assert.equal((await fetch(`${server.origin}/asset/%2e%2e%2fregistry`)).status, 404);
  assert.equal((await fetch(server.assetURL('unknown'))).status, 404);
  assert.equal((await fetch(server.assetURL('harbor'), {method: 'POST'})).status, 405);
  await server.close();
  await symlink(join(root, 'M', 'media', 'harbor.png'), join(root, 'M', 'media', 'linked.png'));
  await assert.rejects(startAssetServer({fixtureRoot: root, snapshot: {sources: [{fixtureId: 'M', sourceId: 'linked', status: 'selected', path: 'M/media/linked.png'}]}, fixtureId: 'M'}), /unavailable/);
});
