import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {createReadStream} from 'node:fs';
import {mkdir, readFile, realpath, stat, writeFile} from 'node:fs/promises';
import {basename, dirname, isAbsolute, join, relative, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';

const execute = promisify(execFile);
const sourceFile = fileURLToPath(import.meta.url);
const sourceDirectory = dirname(sourceFile);
const decoderSource = join(sourceDirectory, 'imageio-prep.swift');
const acceptedCommit = '8a3daf1978093a3d67649b8f3779a9aa15fab876';

const stable = value => Array.isArray(value) ? value.map(stable) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])])) : value;
const digest = value => createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');
const fileHash = async file => {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
};

function inside(root, candidate) {
  const value = relative(root, candidate);
  if (value && !value.startsWith('..') && !isAbsolute(value)) return candidate;
  throw new Error('path escapes owned root');
}

async function ownedPath(root, relativePath) {
  if (typeof relativePath !== 'string' || !relativePath || isAbsolute(relativePath)) throw new Error('path must be relative');
  const realRoot = await realpath(root);
  return inside(realRoot, resolve(realRoot, relativePath));
}

async function compileDecoder(outputRoot) {
  const binary = join(outputRoot, 'bin', 'imageio-prep');
  await mkdir(dirname(binary), {recursive: true});
  await execute('xcrun', ['swiftc', '-O', decoderSource, '-o', binary]);
  const [swift, os] = await Promise.all([
    execute('swift', ['--version']).then(result => result.stdout.trim()),
    execute('sw_vers', []).then(result => result.stdout.trim())
  ]);
  return {binary, identity: {buildSourceSha256: await fileHash(decoderSource), name: 'macOS ImageIO/CoreGraphics', os: os, swift: swift}};
}

function sourceEntry(manifest, sourceId) {
  const source = manifest.sources.find(item => item.id === sourceId);
  if (!source) throw new Error(`unknown source id: ${sourceId}`);
  if (source.container !== 'heic') throw new Error(`${sourceId} is not an HEIC source`);
  return source;
}

function colorWithoutBytes(color) {
  const value = structuredClone(color);
  if (value.iccData) {
    value.iccSha256 = createHash('sha256').update(Buffer.from(value.iccData, 'base64')).digest('hex');
    delete value.iccData;
  }
  return value;
}

export function expectedOriginalsFromSnapshot(snapshot, fixtureId = 'M') {
  const manifest = snapshot?._manifests?.[fixtureId]?.manifest;
  if (!manifest) throw new Error(`missing accepted ${fixtureId} fixture snapshot`);
  return Object.fromEntries(manifest.sources.map(source => [source.id, source.sha256]));
}

export async function validateManifest(manifest, {derivativeRoot, expectedOriginals}) {
  if (manifest?.schemaVersion !== 1 || !Array.isArray(manifest.entries)) throw new Error('invalid derivative manifest');
  if (!expectedOriginals || typeof expectedOriginals !== 'object') throw new Error('accepted source identities are required');
  const root = await realpath(derivativeRoot);
  const sourceIds = new Set();
  for (const entry of manifest.entries) {
    if (!entry || typeof entry.sourceId !== 'string' || sourceIds.has(entry.sourceId)) throw new Error('duplicate or invalid source id');
    sourceIds.add(entry.sourceId);
    if (!(entry.sourceId in expectedOriginals)) throw new Error(`unknown source id: ${entry.sourceId}`);
    if (entry.original?.sha256 !== expectedOriginals[entry.sourceId]) throw new Error(`original hash mismatch: ${entry.sourceId}`);
    const prepared = await ownedPath(root, entry.prepared?.path);
    const details = await stat(prepared);
    if (!details.isFile()) throw new Error(`prepared output is not a file: ${entry.sourceId}`);
    if (await fileHash(prepared) !== entry.prepared.sha256) throw new Error(`prepared hash mismatch: ${entry.sourceId}`);
  }
  return manifest.entries.map(entry => ({sourceId: entry.sourceId, path: entry.prepared.path, sha256: entry.prepared.sha256}));
}

export async function prepareMedia({derivativeRoot, fixtureRoot, sourceIds = ['lpMismatchStill', 'station']}) {
  if (new Set(sourceIds).size !== sourceIds.length) throw new Error('source ids must be unique');
  await mkdir(derivativeRoot, {recursive: true});
  const root = await realpath(derivativeRoot);
  const fixture = await realpath(fixtureRoot);
  const manifest = JSON.parse(await readFile(join(fixture, 'M', 'manifest.json'), 'utf8'));
  const decoder = await compileDecoder(root);
  const entries = [];
  for (const sourceId of [...sourceIds].sort()) {
    const source = sourceEntry(manifest, sourceId);
    const original = await ownedPath(fixture, join('M', source.path));
    const originalSha256 = await fileHash(original);
    if (originalSha256 !== source.sha256) throw new Error(`original hash mismatch: ${sourceId}`);
    const preparedPath = join('prepared', 'M', `${sourceId}.png`);
    const prepared = await ownedPath(root, preparedPath);
    await mkdir(dirname(prepared), {recursive: true});
    const result = JSON.parse((await execute(decoder.binary, [original, prepared])).stdout);
    entries.push({
      sourceId,
      original: {path: join('M', source.path), sha256: originalSha256},
      prepared: {path: preparedPath, sha256: await fileHash(prepared)},
      sourceDimensions: result.sourceDimensions,
      outputDimensions: result.outputDimensions,
      sourceBitDepth: result.sourceBitDepth,
      outputBitDepth: result.outputBitDepth,
      primaryImageIndex: result.primaryImageIndex,
      primaryImageCount: result.primaryImageCount,
      orientation: result.orientation,
      alpha: result.alpha,
      color: {source: colorWithoutBytes(result.color.source), output: colorWithoutBytes(result.color.output)},
      decodedPixelDigest: result.decodedPixelDigest,
      sourceType: result.sourceType,
      outputType: result.outputType
    });
  }
  const settings = {format: 'png', orientation: 'baked-into-pixels', outputExifOrientation: 1, sourceIds: entries.map(entry => entry.sourceId)};
  const output = {schemaVersion: 1, acceptedFixtureCommit: acceptedCommit, fixtureId: 'M', decoder: decoder.identity, settings, settingsDigest: digest(settings), entries};
  output.manifestDigest = digest(output);
  const manifestPath = await ownedPath(root, 'manifest.json');
  await writeFile(manifestPath, `${JSON.stringify(stable(output), null, 2)}\n`);
  await validateManifest(output, {derivativeRoot: root, expectedOriginals: Object.fromEntries(manifest.sources.map(source => [source.id, source.sha256]))});
  return {manifest: output, manifestPath: 'manifest.json'};
}

function parseArguments(values) {
  const options = {sourceIds: []};
  for (let index = 0; index < values.length; index += 1) {
    const key = values[index];
    const value = values[index + 1];
    if (!key.startsWith('--') || value === undefined) throw new Error('invalid arguments');
    if (key === '--source') options.sourceIds.push(value);
    else options[key.slice(2)] = value;
    index += 1;
  }
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === sourceFile) {
  const options = parseArguments(process.argv.slice(2));
  const result = await prepareMedia({derivativeRoot: options['derivative-root'], fixtureRoot: options['fixture-root'], sourceIds: options.sourceIds.length ? options.sourceIds : undefined});
  process.stdout.write(`${JSON.stringify({manifestDigest: result.manifest.manifestDigest, manifestPath: result.manifestPath})}\n`);
}
