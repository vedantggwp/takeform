import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {createReadStream} from 'node:fs';
import {mkdtemp, readFile, rm, symlink} from 'node:fs/promises';
import os from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {prepareMedia, validateManifest} from './media-prep.mjs';

const fixtureRoot = process.env.TAKEFORM_FIXTURE_ROOT;
const execute = (file, args) => new Promise((resolve, reject) => execFile(file, args, (error, stdout, stderr) => error ? reject(new Error(stderr)) : resolve(stdout)));
const hash = async file => {
  const crypto = await import('node:crypto');
  const value = crypto.createHash('sha256');
  for await (const chunk of createReadStream(file)) value.update(chunk);
  return value.digest('hex');
};

test('prepares immutable HEIC sources into deterministic, bound PNG derivatives', async t => {
  assert.ok(fixtureRoot, 'set TAKEFORM_FIXTURE_ROOT to the accepted frozen fixture root');
  const temporary = await mkdtemp(join(os.tmpdir(), 'takeform-media-prep-'));
  t.after(() => rm(temporary, {recursive: true, force: true}));
  const manifest = JSON.parse(await readFile(join(fixtureRoot, 'M', 'manifest.json'), 'utf8'));
  const expectedOriginals = Object.fromEntries(manifest.sources.map(source => [source.id, source.sha256]));
  const originals = await Promise.all(['lp-mismatch.heic', 'station.heic'].map(file => hash(join(fixtureRoot, 'M', 'media', file))));
  const first = await prepareMedia({fixtureRoot, derivativeRoot: join(temporary, 'first')});
  const second = await prepareMedia({fixtureRoot, derivativeRoot: join(temporary, 'second')});
  assert.deepEqual(await validateManifest(first.manifest, {derivativeRoot: join(temporary, 'first'), expectedOriginals}), first.manifest.entries.map(entry => ({sourceId: entry.sourceId, path: entry.prepared.path, sha256: entry.prepared.sha256})));
  assert.deepEqual(first.manifest.entries.map(entry => entry.prepared.sha256), second.manifest.entries.map(entry => entry.prepared.sha256));
  assert.deepEqual(originals, await Promise.all(['lp-mismatch.heic', 'station.heic'].map(file => hash(join(fixtureRoot, 'M', 'media', file)))));
  const station = first.manifest.entries.find(entry => entry.sourceId === 'station');
  assert.deepEqual(station.orientation, {sourceExif: 6, outputExif: 1, treatment: 'baked-into-pixels'});
  assert.deepEqual(station.outputDimensions, {width: 1080, height: 1920});
  assert.equal(station.alpha.source, false);
  assert.equal(station.alpha.output, false);
  assert.equal(station.color.source.iccSha256, station.color.output.iccSha256);
  const synthetic = JSON.parse(await execute(join(temporary, 'first', 'bin', 'imageio-prep'), ['--self-test', join(temporary, 'synthetic')]));
  assert.equal(synthetic.alpha.source, true);
  assert.equal(synthetic.alpha.output, true);
  assert.deepEqual(synthetic.outputDimensions, {width: 3, height: 2});
  assert.deepEqual(synthetic.orientationCases.map(entry => [entry.exif, entry.width, entry.height, entry.alpha]), [[1, 2, 3, true], [2, 2, 3, true], [3, 2, 3, true], [4, 2, 3, true], [5, 3, 2, true], [6, 3, 2, true], [7, 3, 2, true], [8, 3, 2, true]]);
});

test('rejects duplicate, unknown, mismatched and escaping manifest entries', async t => {
  assert.ok(fixtureRoot, 'set TAKEFORM_FIXTURE_ROOT to the accepted frozen fixture root');
  const temporary = await mkdtemp(join(os.tmpdir(), 'takeform-media-prep-'));
  t.after(() => rm(temporary, {recursive: true, force: true}));
  const fixtureManifest = JSON.parse(await readFile(join(fixtureRoot, 'M', 'manifest.json'), 'utf8'));
  const expectedOriginals = Object.fromEntries(fixtureManifest.sources.map(source => [source.id, source.sha256]));
  const manifest = JSON.parse(await readFile(join(process.env.TAKEFORM_DERIVATIVE_ROOT, 'manifest.json'), 'utf8'));
  const attempt = async mutate => {
    const value = structuredClone(manifest);
    mutate(value);
    await validateManifest(value, {derivativeRoot: process.env.TAKEFORM_DERIVATIVE_ROOT, expectedOriginals});
  };
  await assert.rejects(() => attempt(value => value.entries.push(structuredClone(value.entries[0]))), /duplicate/);
  await assert.rejects(() => attempt(value => { value.entries[0].sourceId = 'unknown'; }), /unknown/);
  await assert.rejects(() => attempt(value => { value.entries[0].original.sha256 = '0'.repeat(64); }), /original hash mismatch/);
  await assert.rejects(() => attempt(value => { value.entries[0].prepared.path = '../escape.png'; }), /escapes/);
  const escaped = {schemaVersion: 1, entries: [structuredClone(manifest.entries.find(entry => entry.sourceId === 'station'))]};
  await symlink(join(fixtureRoot, 'M', 'media', 'station.heic'), join(temporary, 'escaped.png'));
  escaped.entries[0].prepared.path = 'escaped.png';
  escaped.entries[0].prepared.sha256 = expectedOriginals.station;
  await assert.rejects(() => validateManifest(escaped, {derivativeRoot: temporary, expectedOriginals}), /escapes/);
});
