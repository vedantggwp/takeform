import {createServer} from 'node:http';
import {lstat, realpath, stat, createReadStream} from 'node:fs';
import {promisify} from 'node:util';
import {basename, relative, resolve} from 'node:path';

const lstatAsync = promisify(lstat);
const realpathAsync = promisify(realpath);
const statAsync = promisify(stat);

const isInside = (root, candidate) => {
  const value = relative(root, candidate);
  return value !== '' && !value.startsWith('..') && !value.includes('../');
};

const contentType = file => ({
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.m4a': 'audio/mp4', '.wav': 'audio/wav',
})[file.slice(file.lastIndexOf('.')).toLowerCase()] ?? 'application/octet-stream';

const parseRange = (header, size) => {
  if (!header) return {start: 0, end: size - 1};
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match) return null;
  const start = match[1] === '' ? size - Number(match[2]) : Number(match[1]);
  const end = match[2] === '' ? size - 1 : Number(match[2]);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end >= size) return null;
  return {start, end};
};

async function ownedFiles(rootPath, entries) {
  const root = await realpathAsync(rootPath);
  const files = new Map();
  for (const entry of entries) {
    if (!entry || typeof entry.sourceId !== 'string' || typeof entry.path !== 'string' || files.has(entry.sourceId)) throw new Error('prepared sources must have unique source IDs and relative paths');
    const lexical = resolve(root, entry.path);
    if (!isInside(root, lexical)) throw new Error(`prepared path escaped derivative root for ${entry.sourceId}`);
    const details = await lstatAsync(lexical);
    if (details.isSymbolicLink() || !details.isFile()) throw new Error(`prepared source is unavailable for ${entry.sourceId}`);
    const physical = await realpathAsync(lexical);
    if (!isInside(root, physical)) throw new Error(`prepared path escaped derivative root for ${entry.sourceId}`);
    files.set(entry.sourceId, physical);
  }
  return files;
}

async function grantsFor({fixtureRoot, snapshot, fixtureId, derivativeRoot, derivativeSources = []}) {
  const root = await realpathAsync(fixtureRoot);
  if (!Array.isArray(derivativeSources) || (derivativeSources.length > 0 && !derivativeRoot)) throw new Error('prepared sources require an explicit derivative root');
  const prepared = derivativeSources.length > 0 ? await ownedFiles(derivativeRoot, derivativeSources) : new Map();
  const selected = new Set(snapshot.sources.filter(item => item.fixtureId === fixtureId && item.status === 'selected').map(item => item.sourceId));
  for (const sourceId of prepared.keys()) if (!selected.has(sourceId)) throw new Error(`prepared source is not selected for ${fixtureId}: ${sourceId}`);
  const grants = new Map();
  for (const source of snapshot.sources.filter(item => item.fixtureId === fixtureId && item.status === 'selected')) {
    if (prepared.has(source.sourceId)) {
      grants.set(source.sourceId, prepared.get(source.sourceId));
      continue;
    }
    const lexical = resolve(root, source.path);
    if (!isInside(root, lexical)) throw new Error(`source path escaped fixture root for ${source.sourceId}`);
    const details = await lstatAsync(lexical);
    if (details.isSymbolicLink() || !details.isFile()) throw new Error(`source is unavailable for ${source.sourceId}`);
    const physical = await realpathAsync(lexical);
    if (!isInside(root, physical)) throw new Error(`source path escaped fixture root for ${source.sourceId}`);
    grants.set(source.sourceId, physical);
  }
  if (grants.size === 0) throw new Error(`fixture ${fixtureId} has no selected sources`);
  return grants;
}

export async function startAssetServer({fixtureRoot, snapshot, fixtureId, derivativeRoot, derivativeSources}) {
  const grants = await grantsFor({fixtureRoot, snapshot, fixtureId, derivativeRoot, derivativeSources});
  const server = createServer(async (request, response) => {
    if (!request.url || !['GET', 'HEAD'].includes(request.method)) {
      response.writeHead(405, {'Allow': 'GET, HEAD'});
      response.end();
      return;
    }
    const match = /^\/asset\/([A-Za-z0-9._-]+)$/.exec(new URL(request.url, 'http://127.0.0.1').pathname);
    const file = match ? grants.get(match[1]) : null;
    if (!file) {
      response.writeHead(404);
      response.end();
      return;
    }
    try {
      const details = await statAsync(file);
      const range = parseRange(request.headers.range, details.size);
      if (!range) {
        response.writeHead(416, {'Content-Range': `bytes */${details.size}`});
        response.end();
        return;
      }
      const length = range.end - range.start + 1;
      response.writeHead(request.headers.range ? 206 : 200, {
        'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store', 'Content-Length': length, 'Content-Range': `bytes ${range.start}-${range.end}/${details.size}`, 'Content-Type': contentType(file), 'X-Content-Type-Options': 'nosniff',
      });
      if (request.method === 'HEAD') return response.end();
      createReadStream(file, range).pipe(response);
    } catch {
      response.writeHead(404);
      response.end();
    }
  });
  await new Promise((resolveStart, rejectStart) => {
    server.once('error', rejectStart);
    server.listen(0, '127.0.0.1', resolveStart);
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('loopback server did not provide a TCP address');
  const origin = `http://127.0.0.1:${address.port}`;
  return Object.freeze({origin, assetURL: sourceId => `${origin}/asset/${encodeURIComponent(sourceId)}`, close: () => new Promise(resolveClose => server.close(resolveClose)), grantedSourceIds: [...grants.keys()].sort()});
}
