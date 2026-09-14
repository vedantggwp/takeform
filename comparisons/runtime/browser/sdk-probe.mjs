import {createServer} from 'node:http';
import {mkdir, writeFile} from 'node:fs/promises';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

function parseArgs(argv) {
  const options = {artifacts: null, runtime: null, sdk: null, wrapper: null, scratch: null};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!['--artifacts', '--runtime', '--sdk', '--wrapper', '--scratch'].includes(argument)) throw new Error('Invalid probe argument');
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error('Missing probe argument value');
    index += 1;
    options[argument.slice(2)] = argument === '--sdk' ? value : resolve(value);
  }
  if (Object.values(options).some((value) => value === null)) throw new Error('Missing probe configuration');
  return options;
}

async function importPackage(runtime, name) {
  const metadata = JSON.parse(readFileSync(join(runtime, 'node_modules', name, 'package.json'), 'utf8'));
  const rootExport = metadata.exports?.['.'];
  const entry = typeof rootExport === 'string' ? rootExport : rootExport?.import ?? rootExport?.module ?? metadata.module ?? metadata.main;
  return {module: await import(pathToFileURL(join(runtime, 'node_modules', name, entry)).href), version: metadata.version};
}

function dimensions(buffer, format) {
  if (format === 'png') return {height: buffer.readUInt32BE(20), width: buffer.readUInt32BE(16)};
  for (let index = 2; index < buffer.length - 9; index += 1) {
    if (buffer[index] !== 0xff || buffer[index + 1] < 0xc0 || buffer[index + 1] > 0xc3) continue;
    return {height: buffer.readUInt16BE(index + 5), width: buffer.readUInt16BE(index + 7)};
  }
  throw new Error('Invalid JPEG capture');
}

async function retain(options, name, buffer, format) {
  await mkdir(options.artifacts, {recursive: true});
  await writeFile(join(options.artifacts, name), buffer);
  return {
    dimensions: dimensions(buffer, format),
    name,
    sha256: createHash('sha256').update(buffer).digest('hex'),
  };
}

function result(status, fields = {}) {
  process.stdout.write(`${JSON.stringify({status, ...fields})}\n`);
}

function classify(error) {
  const detail = error instanceof Error ? error.message : '';
  if (detail.includes('BROWSER_WRAPPER_REJECTED_SECURITY_ARGUMENT')) return 'SECURITY_ARGUMENT_REJECTED';
  if (detail.includes('BROWSER_WRAPPER_TARGET_UNAVAILABLE')) return 'EXECUTABLE_FAILURE';
  if (/old headless mode|headless.*removed/i.test(detail)) return 'OLD_HEADLESS_REMOVED';
  if (/HeadlessExperimental|method.*not found|Page\.captureScreenshot|_client.*function/i.test(detail)) return 'UNSUPPORTED_PROTOCOL_METHOD';
  if (/window\.__hf|page\.goto|navigation|not ready|initialize/i.test(detail)) return 'INITIALIZATION_FAILED';
  if (/browser process|executable|spawn|chrome/i.test(detail)) return 'EXECUTABLE_FAILURE';
  return 'SDK_OPERATION_FAILED';
}

async function startCompositionServer() {
  const html = '<!doctype html><html><body data-probe-marker="hyperframes-browser-probe"><main id="frame">hyperframes-browser-probe</main><script>window.__hf={duration:1,seek:(time)=>{document.getElementById("frame").dataset.frame=String(time)}}</script></body></html>';
  const server = createServer((request, response) => {
    if (request.url === '/index.html') {
      response.writeHead(200, {'content-type': 'text/html; charset=utf-8'});
      response.end(html);
      return;
    }
    response.writeHead(404);
    response.end();
  });
  await new Promise((resolveListen, rejectListen) => {
    server.once('error', rejectListen);
    server.listen(0, '127.0.0.1', resolveListen);
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Composition server unavailable');
  return {
    close: () => new Promise((resolveClose) => server.close(() => resolveClose())),
    url: `http://127.0.0.1:${address.port}`,
  };
}

let phase = 'startup';

async function remotion(options) {
  const {module: renderer, version} = await importPackage(options.runtime, '@remotion/renderer');
  phase = 'launch';
  const browser = await renderer.openBrowser('chrome', {
    browserExecutable: options.wrapper,
    chromeMode: 'chrome-for-testing',
    chromiumOptions: {headless: true},
    logLevel: 'error',
  });
  let artifact;
  let cleanup = 'closed';
  try {
    phase = 'page';
    const page = await browser.newPage({context: () => null, indent: false, logLevel: 'error', onBrowserLog: null, onLog: () => undefined, pageIndex: 0});
    try {
      phase = 'navigate';
      await page.goto({url: 'data:text/html,<main data-probe-marker="remotion-browser-probe">remotion-browser-probe</main>', timeout: 5000});
      phase = 'capture';
      const screenshot = await page._client().send('Page.captureScreenshot', {format: 'png'});
      artifact = await retain(options, 'remotion-blank.png', Buffer.from(screenshot.value.data, 'base64'), 'png');
    } finally {
      try {
        await page.close();
      } catch {
        cleanup = 'page-close-failed';
      }
    }
  } finally {
    try {
      await browser.close({silent: true});
    } catch {
      cleanup = cleanup === 'closed' ? 'browser-close-failed' : cleanup;
    }
  }
  phase = 'complete';
  result('ok', {artifact, capture: 'png', cleanup, headlessMode: 'new', sdk: '@remotion/renderer', version});
}

async function hyperframes(options) {
  const {module: engine, version} = await importPackage(options.runtime, '@hyperframes/engine');
  phase = 'composition-server';
  const server = await startCompositionServer();
  let session;
  let cleanup = 'closed';
  let artifact;
  const previousLog = console.log;
  console.log = () => undefined;
  try {
    phase = 'create-session';
    session = await engine.createCaptureSession(server.url, options.scratch, {format: 'jpeg', fps: {num: 30, den: 1}, height: 64, width: 64}, null, {
      browserGpuMode: 'software',
      browserTimeout: 5000,
      chromePath: options.wrapper,
      enableBrowserPool: false,
      forceScreenshot: false,
      protocolTimeout: 5000,
    });
    phase = 'initialize';
    await engine.initializeSession(session);
    phase = 'capture';
    const captured = await engine.captureFrameToBuffer(session, 0, 0);
    artifact = await retain(options, 'hyperframes-blank.jpg', captured.buffer, 'jpeg');
  } finally {
    phase = 'cleanup';
    try {
      if (session) await engine.closeCaptureSession(session);
      await server.close();
    } catch {
      cleanup = 'close-failed';
    }
    console.log = previousLog;
  }
  phase = 'complete';
  result('ok', {artifact, capture: 'jpeg', cleanup, mode: session.captureMode, sdk: '@hyperframes/engine', version});
}

const options = parseArgs(process.argv.slice(2));
try {
  if (options.sdk === 'remotion') await remotion(options);
  else if (options.sdk === 'hyperframes') await hyperframes(options);
  else throw new Error('Unknown SDK');
} catch (error) {
  result('error', {code: classify(error), phase});
  process.exitCode = 1;
}
