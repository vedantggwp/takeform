import {mkdir} from 'node:fs/promises';
import {isAbsolute, join} from 'node:path';
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
  const attempt = createAttempt({id: attemptId, snapshot, backend: {kind: 'renderer', identity: 'remotion', version: '4.0.524'}, attemptRoot, scratchPaths: [join(attemptRoot, 'bundle')], outputPath: join(attemptRoot, 'output.mp4')});
  return Object.freeze({attempt, fixtureId, rate: rate.num / rate.den, frameCount: expected.frameCount, dimensions: {width: manifest.canonicalPlan.width, height: manifest.canonicalPlan.height}, storage});
}

export async function bundleAndRender({prepared, runtime, entryPoint, props, browserExecutable}) {
  if (!isAbsolute(runtime) || !isAbsolute(entryPoint) || !isAbsolute(browserExecutable)) throw new Error('runtime, entryPoint, and browser executable must be absolute paths');
  await mkdir(prepared.attempt.attemptRoot, {recursive: true});
  await Promise.all(prepared.attempt.scratchPaths.map(directory => mkdir(directory, {recursive: true})));
  const [bundler, renderer] = await Promise.all([import(bundlerModule(runtime)), import(rendererModule(runtime))]);
  const serveUrl = await bundler.bundle({entryPoint, outDir: prepared.attempt.scratchPaths[0]});
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
