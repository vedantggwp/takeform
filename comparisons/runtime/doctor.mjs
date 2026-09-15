#!/usr/bin/env node

import {readFileSync} from 'node:fs';
import {access, stat} from 'node:fs/promises';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {spawn} from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const packages = [
  ['@hyperframes/producer', '0.8.39'],
  ['@hyperframes/engine', '0.8.39'],
  ['@hyperframes/player', '0.8.39'],
  ['@hyperframes/player/node_modules/@hyperframes/core', '0.8.39'],
  ['@hyperframes/core', '0.8.40'],
  ['@remotion/bundler', '4.0.524'],
  ['remotion', '4.0.524'],
  ['@remotion/renderer', '4.0.524'],
  ['@remotion/player', '4.0.524'],
];
const maxOutputBytes = 4096;
const terminationGraceMs = 100;

function parseArgs(argv) {
  const options = {
    browser: null,
    bootstrapBrowser: false,
    ffmpeg: 'ffmpeg',
    nodeVersion: process.version,
    packageOnly: false,
    runtime: here,
    timeoutMs: 5000,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--bootstrap-browser') {
      options.bootstrapBrowser = true;
      continue;
    }
    if (argument === '--package-only') {
      options.packageOnly = true;
      continue;
    }
    if (argument === '--browser' || argument === '--ffmpeg' || argument === '--node-version' || argument === '--runtime' || argument === '--timeout-ms') {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) {
        throw new Error(`Missing value for ${argument}`);
      }
      index += 1;
      if (argument === '--browser') options.browser = value;
      if (argument === '--ffmpeg') options.ffmpeg = value;
      if (argument === '--node-version') options.nodeVersion = value;
      if (argument === '--runtime') options.runtime = resolve(value);
      if (argument === '--timeout-ms') options.timeoutMs = Number(value);
      continue;
    }
    throw new Error(`Unknown argument ${argument}`);
  }

  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 100 || options.timeoutMs > 30000) {
    throw new Error('--timeout-ms must be an integer from 100 to 30000');
  }
  return options;
}

function publicPath(pathname) {
  return pathname ? 'provided' : 'not-provided';
}

function publicVersion(output) {
  const line = output.split('\n')[0].trim().slice(0, 512);
  return line.replace(/(?:^|\s)(?:\/|~\/)[^\s]*/g, ' [path]');
}

function diagnostic(error, subject) {
  const code = typeof error === 'object' && error !== null && typeof error.code === 'string'
    ? error.code
    : error instanceof Error
      ? error.name
      : 'UNKNOWN';
  return {code, message: `${subject} failed`};
}

function command(executable, args, timeoutMs) {
  return new Promise((resolveCommand) => {
    let settled = false;
    let timedOut = false;
    let terminated = false;
    let killTimer;
    let timeout;
    let stdout = '';
    let stderr = '';
    const append = (value, chunk) => {
      if (Buffer.byteLength(value) >= maxOutputBytes) return value;
      const remaining = maxOutputBytes - Buffer.byteLength(value);
      return value + chunk.toString('utf8').slice(0, remaining);
    };
    const finish = (result) => {
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        clearTimeout(killTimer);
        resolveCommand(result);
      }
    };
    let child;
    try {
      child = spawn(executable, args, {stdio: ['ignore', 'pipe', 'pipe']});
    } catch (error) {
      finish({status: 'error', error: diagnostic(error, 'Executable')});
      return;
    }
    timeout = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      killTimer = setTimeout(() => {
        terminated = true;
        child.kill('SIGKILL');
      }, terminationGraceMs);
    }, timeoutMs);
    child.stdout.on('data', (chunk) => { stdout = append(stdout, chunk); });
    child.stderr.on('data', (chunk) => { stderr = append(stderr, chunk); });
    child.on('error', (error) => finish({status: 'error', error: diagnostic(error, 'Executable')}));
    child.on('close', (code, signal) => {
      if (timedOut) {
        finish({status: 'timeout', reaped: true, signal: signal ?? (terminated ? 'SIGKILL' : 'SIGTERM')});
        return;
      }
      finish({status: code === 0 ? 'ok' : 'error', code, stdout, stderr});
    });
  });
}

async function importPackage(runtime, name) {
  const metadataPath = join(runtime, 'node_modules', name, 'package.json');
  const metadata = JSON.parse(readFileSync(metadataPath, 'utf8'));
  const rootExport = metadata.exports?.['.'];
  const entry = typeof rootExport === 'string'
    ? rootExport
    : rootExport?.import ?? rootExport?.module ?? metadata.module ?? metadata.main;
  if (!entry) {
    const error = new Error('Package has no import entrypoint');
    error.code = 'NO_ENTRYPOINT';
    throw error;
  }
  return {
    metadata,
    module: await import(pathToFileURL(join(runtime, 'node_modules', name, entry)).href),
  };
}

function nodeStatus(version) {
  const major = Number(/^v?(\d+)/.exec(version)?.[1]);
  if (!Number.isInteger(major) || major < 22 || major >= 23) {
    return {status: 'error', version, error: 'Node 22 is required by this runtime'};
  }
  return {status: 'ok', version};
}

async function packageStatus(runtime, name, expectedVersion) {
  try {
    const metadata = JSON.parse(readFileSync(join(runtime, 'node_modules', name, 'package.json'), 'utf8'));
    if (metadata.version !== expectedVersion) {
      return {status: 'error', version: metadata.version, error: `Expected ${expectedVersion}`};
    }
    return {status: 'ok', version: metadata.version};
  } catch (error) {
    return {status: 'error', error: diagnostic(error, `${name} package metadata`)};
  }
}

function exportedFunctions(module, names) {
  return names.filter((name) => typeof module[name] !== 'function');
}

async function importsStatus(runtime) {
  const result = {};
  try {
    const producer = await importPackage(runtime, '@hyperframes/producer');
    const publicApis = ['createRenderJob', 'executeRenderJob'];
    const missing = exportedFunctions(producer.module, publicApis);
    if (missing.length > 0) {
      result.hyperframes = {status: 'error', error: {code: 'MISSING_EXPORT', message: 'HyperFrames producer API is unavailable'}, missing};
    } else {
      const job = producer.module.createRenderJob({
        format: 'mp4',
        fps: {num: 24000, den: 1001},
        quality: 'standard',
        workers: 1,
      });
      result.hyperframes = {
        status: 'ok',
        exactRationalConfig: job.config.fps,
        publicApis,
      };
    }
  } catch (error) {
    result.hyperframes = {status: 'error', error: diagnostic(error, 'HyperFrames producer import')};
  }

  try {
    const renderer = await importPackage(runtime, '@remotion/renderer');
    const bundler = await importPackage(runtime, '@remotion/bundler');
    await importPackage(runtime, 'remotion');
    const publicApis = ['ensureBrowser', 'openBrowser', 'renderMedia'];
    const bundlerPublicApis = ['bundle'];
    const missing = [...exportedFunctions(renderer.module, publicApis), ...exportedFunctions(bundler.module, bundlerPublicApis)];
    result.remotion = {
      status: missing.length === 0 ? 'ok' : 'error',
      publicApis,
      bundlerPublicApis,
    };
    if (result.remotion.status === 'error') {
      result.remotion.error = {code: 'MISSING_EXPORT', message: 'Remotion renderer or bundler API is unavailable'};
      result.remotion.missing = missing;
    }
  } catch (error) {
    result.remotion = {status: 'error', error: diagnostic(error, 'Remotion renderer or bundler import')};
  }
  return result;
}

async function browserStatus(options, imports) {
  const result = {
    candidate: {status: options.browser ? 'pending' : 'not-provided'},
    hyperframes: {
      status: 'not-run',
      reason: 'Pinned launch helpers inject sandbox-disabling flags. This runtime does not use them.',
    },
    remotion: {status: 'not-requested'},
  };
  if (!options.browser) return result;

  const version = await command(options.browser, ['--version'], options.timeoutMs);
  result.candidate = version.status === 'ok'
    ? {status: 'ok', version: publicVersion(version.stdout || version.stderr)}
    : {status: 'error', error: version.error ?? {code: version.status === 'timeout' ? 'TIMEOUT' : 'EXECUTABLE_ERROR', message: 'Browser executable could not be queried'}};

  if (!options.bootstrapBrowser) return result;
  if (version.status !== 'ok') {
    result.remotion = {status: 'error', error: {code: 'BROWSER_UNAVAILABLE', message: 'Browser executable could not be queried'}};
    return result;
  }
  if (imports.remotion.status !== 'ok') {
    result.remotion = {status: 'error', error: {code: 'RENDERER_IMPORT_FAILED', message: 'Remotion renderer import failed'}};
    return result;
  }

  try {
    const renderer = await importPackage(options.runtime, '@remotion/renderer');
    const bootstrap = await renderer.module.ensureBrowser({
      browserExecutable: options.browser,
      logLevel: 'error',
    });
    result.remotion = {
      status: bootstrap.type === 'user-defined-path' ? 'ok' : 'error',
      bootstrap: bootstrap.type,
      path: publicPath(bootstrap.path),
    };
  } catch (error) {
    result.remotion = {status: 'error', error: diagnostic(error, 'Remotion browser bootstrap')};
  }
  return result;
}

async function executableStatus(executable, timeoutMs) {
  const result = await command(executable, ['-version'], timeoutMs);
  if (result.status === 'ok') {
    return {status: 'ok', version: publicVersion(result.stdout)};
  }
  return {status: 'error', executable: publicPath(executable), error: result.error ?? {code: result.status === 'timeout' ? 'TIMEOUT' : 'EXECUTABLE_ERROR', message: 'FFmpeg executable could not be queried'}};
}

async function runtimeStatus(runtime) {
  try {
    await access(runtime);
    const details = await stat(runtime);
    return details.isDirectory() ? {status: 'ok'} : {status: 'error', error: '--runtime must be a directory'};
  } catch (error) {
    return {status: 'error', error: diagnostic(error, 'Runtime directory')};
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const result = {
    browser: null,
    ffmpeg: null,
    imports: null,
    node: nodeStatus(options.nodeVersion),
    packages: {},
    runtime: await runtimeStatus(options.runtime),
  };

  for (const [name, version] of packages) {
    result.packages[name] = await packageStatus(options.runtime, name, version);
  }
  result.imports = await importsStatus(options.runtime);
  result.ffmpeg = options.packageOnly
    ? {status: 'not-requested'}
    : await executableStatus(options.ffmpeg, options.timeoutMs);
  result.browser = options.packageOnly
    ? {candidate: {status: 'not-requested'}, hyperframes: {status: 'not-requested'}, remotion: {status: 'not-requested'}}
    : await browserStatus(options, result.imports);
  result.ok = [
    result.runtime.status,
    result.node.status,
    result.ffmpeg.status === 'not-requested' ? 'ok' : result.ffmpeg.status,
    ...Object.values(result.packages).map((entry) => entry.status),
    result.imports.hyperframes.status,
    result.imports.remotion.status,
    result.browser.candidate.status === 'not-provided' || result.browser.candidate.status === 'not-requested' ? 'ok' : result.browser.candidate.status,
    result.browser.remotion.status === 'not-requested' ? 'ok' : result.browser.remotion.status,
  ].every((status) => status === 'ok');
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  process.exitCode = result.ok ? 0 : 1;
}

main().catch((error) => {
  process.stdout.write(`${JSON.stringify({ok: false, error: diagnostic(error, 'Doctor')}, null, 2)}\n`);
  process.exitCode = 1;
});
