import assert from 'node:assert/strict';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {bundleAttempt} from '../render-attempt.mjs';

test('requires an attempt-owned TMPDIR before importing the SDK', async context => {
  const root = await mkdtemp(join(tmpdir(), 'takeform-remotion-attempt-'));
  context.after(() => rm(root, {recursive: true, force: true}));
  const previous = process.env.TMPDIR;
  context.after(() => {
    if (previous === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previous;
  });
  process.env.TMPDIR = join(root, 'other');
  await assert.rejects(
    bundleAttempt({prepared: {attempt: {attemptRoot: root, scratchPaths: [join(root, 'bundle'), join(root, 'tmp')]}}, runtime: '/runtime', entryPoint: '/entry.mjs'}),
    /TMPDIR must name this attempt's owned tmp directory/
  );
});
