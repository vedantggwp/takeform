import {createServer} from 'node:http';
import {createReadStream} from 'node:fs';
import {realpath, stat} from 'node:fs/promises';
import {extname, resolve, sep} from 'node:path';

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) args.set(process.argv[index], process.argv[index + 1]);
if (Number(process.versions.node.split('.')[0]) !== 22) {
  process.stdout.write(`${JSON.stringify({status: 'error', message: 'Node 22 is required for this comparison host.'})}\n`);
  process.exit(1);
}
const port = Number(args.get('--port'));
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('invalidPort');

async function grantedRoot(flag) {
  const value = args.get(flag);
  return value ? realpath(value) : undefined;
}

let roots;
try {
  roots = {bundle: await grantedRoot('--bundle-root'), fixtures: await grantedRoot('--fixture-root')};
} catch {
  process.stdout.write(`${JSON.stringify({status: 'error', message: 'An explicitly granted local root is unavailable.'})}\n`);
  process.exit(1);
}
const types = new Map([['.html', 'text/html; charset=utf-8'], ['.js', 'text/javascript; charset=utf-8'], ['.mjs', 'text/javascript; charset=utf-8'], ['.css', 'text/css; charset=utf-8'], ['.json', 'application/json'], ['.mp4', 'video/mp4'], ['.webm', 'video/webm'], ['.png', 'image/png'], ['.jpg', 'image/jpeg'], ['.jpeg', 'image/jpeg'], ['.svg', 'image/svg+xml'], ['.woff2', 'font/woff2']]);

function reject(response, status) {
  response.writeHead(status, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
  response.end(status === 404 ? 'Not found' : 'Rejected');
}

function byteRange(value, size) {
  if (!value) return undefined;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || size < 1) return null;
  if (match[1] === '') {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix < 1) return null;
    return {start: Math.max(0, size - suffix), end: size - 1};
  }
  const start = Number(match[1]);
  const requestedEnd = match[2] === '' ? size - 1 : Number(match[2]);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(requestedEnd) || start >= size || requestedEnd < start) return null;
  return {start, end: Math.min(requestedEnd, size - 1)};
}

async function servedPath(requestURL) {
  const decoded = decodeURIComponent(requestURL.pathname);
  if (decoded === '/' || decoded === '/diagnostic.html') return new URL('./diagnostic.html', import.meta.url);
  const match = decoded.match(/^\/(bundle|fixtures)\/(.+)$/);
  if (!match || match[2].includes('\0')) return undefined;
  const root = roots[match[1]];
  if (!root) return undefined;
  const candidate = resolve(root, match[2]);
  if (!candidate.startsWith(root + sep)) return undefined;
  const resolved = await realpath(candidate);
  if (!resolved.startsWith(root + sep)) return undefined;
  return resolved;
}

const server = createServer(async (request, response) => {
  if (!request.url || !['GET', 'HEAD'].includes(request.method ?? '')) return reject(response, 405);
  try {
    const location = await servedPath(new URL(request.url, 'http://127.0.0.1'));
    if (!location) return reject(response, 404);
    const info = await stat(location);
    if (!info.isFile()) return reject(response, 404);
    const type = types.get(extname(location).toLowerCase());
    if (!type) return reject(response, 404);
    const range = byteRange(request.headers.range, info.size);
    if (range === null) {
      response.writeHead(416, {'Content-Range': `bytes */${info.size}`, 'Cache-Control': 'no-store'});
      return response.end();
    }
    const headers = {'Content-Type': type, 'Content-Length': range ? range.end - range.start + 1 : info.size, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'};
    if (range) headers['Content-Range'] = `bytes ${range.start}-${range.end}/${info.size}`;
    response.writeHead(range ? 206 : 200, headers);
    if (request.method === 'HEAD') return response.end();
    const input = createReadStream(location, range ?? {});
    input.on('error', () => response.destroy());
    response.on('close', () => input.destroy());
    input.pipe(response);
  } catch {
    reject(response, 404);
  }
});

server.listen({host: '127.0.0.1', port}, () => {
  const address = server.address();
  process.stdout.write(`${JSON.stringify({status: 'ready', host: '127.0.0.1', port: address.port})}\n`);
});
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => server.close(() => process.exit(0)));
