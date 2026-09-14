import {mkdir, mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runBounded} from './runner.mjs';

const here = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const options = {artifacts: join(here, 'artifacts'), browser: null, runtime: null};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!['--artifacts', '--browser', '--runtime'].includes(argument)) throw new Error('Invalid probe argument');
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error('Missing probe argument value');
    index += 1;
    options[argument.slice(2)] = resolve(value);
  }
  if (!options.browser || !options.runtime) throw new Error('Browser and runtime are required');
  return options;
}

const options = parseArgs(process.argv.slice(2));
await mkdir(options.artifacts, {recursive: true});
const results = {};
for (const sdk of ['remotion', 'hyperframes']) {
  const scratch = await mkdtemp(join(tmpdir(), `takeform-${sdk}-probe-`));
  try {
    results[sdk] = await runBounded(process.execPath, [join(here, 'sdk-probe.mjs'), '--artifacts', options.artifacts, '--runtime', options.runtime, '--sdk', sdk, '--wrapper', join(here, 'secure-browser-launcher.sh'), '--scratch', scratch], {
      env: {...process.env, TAKEFORM_BROWSER_EXECUTABLE: options.browser},
    });
  } finally {
    await rm(scratch, {force: true, recursive: true});
  }
}
process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
