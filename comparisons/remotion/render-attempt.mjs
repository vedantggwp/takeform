import {mkdir} from 'node:fs/promises';
import {isAbsolute, join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createAttempt, frameState, reserveStorage} from '../common/index.mjs';

const rendererModule = runtime => pathToFileURL(join(runtime, 'node_modules/@remotion/renderer/dist/esm/index.mjs')).href;
const bundlerModule = runtime => pathToFileURL(join(runtime, 'node_modules/@remotion/bundler/dist/index.js')).href;

export function prepareAttempt({attemptId, attemptRoot, snapshot, fixtureId, runtime, expectedOutputBytes, decodeCacheBytes, pipelineBufferBytes, runtimeFreeFloorBytes, freeBytes}) {
  if (!isAbsolute(runtime)) throw new Error('runtime must be a caller-supplied absolute path');
  const manifest = snapshot._manifests?.[fixtureId]?.manifest;
  if (!manifest) throw new Error(`fixture ${fixtureId} is absent from the accepted snapshot`);
  const expected = manifest.expected;
  const rate = manifest.canonicalPlan.outputFrameRate;
  const storage = reserveStorage({route: 'streaming', width: manifest.canonicalPlan.width, height: manifest.canonicalPlan.height, frameCount: expected.frameCount, expectedOutputBytes, decodeCacheBytes, pipelineBufferBytes, runtimeFreeFloorBytes, freeBytes});
  const attempt = createAttempt({id: attemptId, snapshot, backend: {kind: 'renderer', identity: 'remotion', version: '4.0.524'}, attemptRoot, scratchPaths: [join(attemptRoot, 'bundle'), join(attemptRoot, 'tmp')], outputPath: join(attemptRoot, 'output.mp4')});
  return Object.freeze({attempt, fixtureId, rate: rate.num / rate.den, frameCount: expected.frameCount, dimensions: {width: manifest.canonicalPlan.width, height: manifest.canonicalPlan.height}, storage});
}

const requireAttemptTmpdir = prepared => {
  const tmpdir = prepared.attempt.scratchPaths[1];
  if (!tmpdir || resolve(process.env.TMPDIR ?? '') !== resolve(tmpdir)) throw new Error('TMPDIR must name this attempt\'s owned tmp directory before importing Remotion SDK modules');
  return tmpdir;
};

export async function bundleAttempt({prepared, runtime, entryPoint}) {
  if (!isAbsolute(runtime) || !isAbsolute(entryPoint)) throw new Error('runtime and entry point must be absolute paths');
  await mkdir(prepared.attempt.attemptRoot, {recursive: true});
  await Promise.all(prepared.attempt.scratchPaths.map(directory => mkdir(directory, {recursive: true})));
  requireAttemptTmpdir(prepared);
  const bundler = await import(bundlerModule(runtime));
  return bundler.bundle({entryPoint, outDir: prepared.attempt.scratchPaths[0], webpackOverride: config => ({...config, resolve: {...config.resolve, modules: [...(config.resolve?.modules ?? ['node_modules']), join(runtime, 'node_modules')]}})});
}

export async function bundleAndRender({prepared, runtime, entryPoint, props, browserExecutable}) {
  if (!isAbsolute(browserExecutable)) throw new Error('browser executable must be an absolute path');
  const serveUrl = await bundleAttempt({prepared, runtime, entryPoint});
  const renderer = await import(rendererModule(runtime));
  await renderer.renderMedia({
    serveUrl,
    codec: 'h264',
    composition: {id: `takeform-${prepared.fixtureId}`, width: prepared.dimensions.width, height: prepared.dimensions.height, fps: prepared.rate, durationInFrames: prepared.frameCount},
    inputProps: props,
    outputLocation: prepared.attempt.outputPath,
    browserExecutable,
    chromeMode: 'chrome-for-testing',
    concurrency: 1,
  });
}

export const stateAtFrame = ({snapshot, fixtureId, frame}) => frameState(snapshot, fixtureId, frame);
