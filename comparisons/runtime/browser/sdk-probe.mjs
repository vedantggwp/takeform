import {mkdir, writeFile} from 'node:fs/promises';
import {readFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

function parseArgs(argv) {
  const options = {runtime: null, sdk: null, wrapper: null, scratch: null};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!['--runtime', '--sdk', '--wrapper', '--scratch'].includes(argument)) {
      throw new Error('Invalid probe argument');
    }
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error('Missing probe argument value');
    index += 1;
    options[argument.slice(2)] = argument === '--sdk' ? value : resolve(value);
  }
  if (!options.runtime || !options.sdk || !options.wrapper || !options.scratch) {
    throw new Error('Missing probe configuration');
  }
  return options;
}

async function importPackage(runtime, name) {
  const metadata = JSON.parse(readFileSync(join(runtime, 'node_modules', name, 'package.json'), 'utf8'));
  const rootExport = metadata.exports?.['.'];
  const entry = typeof rootExport === 'string' ? rootExport : rootExport?.import ?? rootExport?.module ?? metadata.module ?? metadata.main;
  return import(pathToFileURL(join(runtime, 'node_modules', name, entry)).href);
}

function result(status, fields = {}) {
  process.stdout.write(`${JSON.stringify({status, ...fields})}\n`);
}

async function remotion(options) {
  const renderer = await importPackage(options.runtime, '@remotion/renderer');
  const browser = await renderer.openBrowser('chrome', {
    browserExecutable: options.wrapper,
    chromiumOptions: {headless: true},
    logLevel: 'error',
  });
  try {
    const page = await browser.newPage({
      context: () => null,
      indent: false,
      logLevel: 'error',
      onBrowserLog: null,
      onLog: () => undefined,
      pageIndex: 0,
    });
    await page.goto({url: 'data:text/html,<title>takeform-browser-probe</title>', timeout: 5000});
    const screenshot = await page._client().send('Page.captureScreenshot', {format: 'png'});
    await mkdir(options.scratch, {recursive: true});
    await writeFile(join(options.scratch, 'remotion-blank.png'), Buffer.from(screenshot.data, 'base64'));
    await page.close();
    result('ok', {capture: 'png'});
  } finally {
    await browser.close({silent: true});
  }
}

async function hyperframes(options) {
  const engine = await importPackage(options.runtime, '@hyperframes/engine');
  await mkdir(options.scratch, {recursive: true});
  const session = await engine.createCaptureSession(
    'data:text/html,<script>window.__hf={duration:1,seek:()=>{}}</script>',
    options.scratch,
    {format: 'jpeg', fps: {num: 30, den: 1}, height: 64, width: 64},
    null,
    {
      browserGpuMode: 'software',
      browserTimeout: 5000,
      chromePath: options.wrapper,
      enableBrowserPool: false,
      forceScreenshot: true,
      protocolTimeout: 5000,
    },
  );
  try {
    await engine.initializeSession(session);
    const captured = await engine.captureFrameToBuffer(session, 0);
    await writeFile(join(options.scratch, 'hyperframes-blank.jpg'), captured.buffer);
    result('ok', {capture: 'jpeg', mode: session.captureMode});
  } finally {
    await engine.closeCaptureSession(session);
  }
}

const options = parseArgs(process.argv.slice(2));
try {
  if (options.sdk === 'remotion') await remotion(options);
  else if (options.sdk === 'hyperframes') await hyperframes(options);
  else throw new Error('Unknown SDK');
} catch (error) {
  const detail = error instanceof Error ? error.message : '';
  result('error', {code: detail.includes('BROWSER_WRAPPER_REJECTED_SECURITY_ARGUMENT') ? 'SECURITY_ARGUMENT_REJECTED' : 'SDK_LAUNCH_FAILED'});
  process.exitCode = 1;
}
