import {mkdtemp, rm} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const timeoutMs = 10000;

function parseArgs(argv) {
  const options = {browser: null, runtime: null};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument !== '--browser' && argument !== '--runtime') throw new Error('Invalid probe argument');
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error('Missing probe argument value');
    index += 1;
    options[argument.slice(2)] = resolve(value);
  }
  if (!options.browser || !options.runtime) throw new Error('Browser and runtime are required');
  return options;
}

function runProbe(options, sdk, scratch) {
  return new Promise((resolveProbe) => {
    let settled = false;
    let timedOut = false;
    let killTimer;
    let timeout;
    let stdout = '';
    const child = spawn(process.execPath, [join(here, 'sdk-probe.mjs'), '--runtime', options.runtime, '--sdk', sdk, '--wrapper', join(here, 'secure-browser-launcher.sh'), '--scratch', scratch], {
      env: {...process.env, TAKEFORM_BROWSER_EXECUTABLE: options.browser},
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const finish = (value) => {
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        clearTimeout(killTimer);
        resolveProbe(value);
      }
    };
    child.stdout.on('data', (chunk) => { stdout = (stdout + chunk.toString('utf8')).slice(0, 1024); });
    child.on('error', () => finish({status: 'error', code: 'PROBE_SPAWN_FAILED'}));
    child.on('close', (code, signal) => {
      if (timedOut) finish({status: 'timeout', reaped: true, signal: signal ?? 'SIGKILL'});
      else {
        try {
          const result = JSON.parse(stdout);
          finish(result);
        } catch {
          finish({status: code === 0 ? 'ok' : 'error', code: 'PROBE_PROTOCOL_ERROR'});
        }
      }
    });
    timeout = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      killTimer = setTimeout(() => child.kill('SIGKILL'), 100);
    }, timeoutMs);
  });
}

const options = parseArgs(process.argv.slice(2));
const results = {};
for (const sdk of ['remotion', 'hyperframes']) {
  const scratch = await mkdtemp(join(tmpdir(), `takeform-${sdk}-probe-`));
  try {
    results[sdk] = await runProbe(options, sdk, scratch);
  } finally {
    await rm(scratch, {force: true, recursive: true});
  }
}
process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
