import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, mkdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {requestProposal} from '../src/proposal-adapter.mjs';
import {startStub} from '../src/stub.mjs';

function slice() { return {revision: 7, artifacts: [{id: 'script:selected', content: 'Selected outline only.'}], commandSchema: [{name: 'proposeScriptChunks', arguments: ['artifactId', 'replacement']}]} ; }
function profile(endpoint, changes = {}) { return {transport: 'openai-compatible', endpoint, model: 'local-structured-stub', accountKind: 'api', capabilities: {structuredProposal: true}, localTestOnly: true, credentialRef: 'opaque-test-only-reference', ...changes}; }
async function withStub(run) { const stub = await startStub(); try { await run(stub); } finally { await stub.close(); } }

test('sends only the supplied slice and validates a proposal', async () => withStub(async (stub) => {
  const cwd = await mkdtemp(join(tmpdir(), 'takeform-provider-context-'));
  const previousCwd = process.cwd();
  try {
    await writeFile(join(cwd, 'AGENTS.md'), 'PRIVATE_CONTEXT_SENTINEL ancestor AGENTS');
    await writeFile(join(cwd, 'unselected.txt'), 'PRIVATE_CONTEXT_SENTINEL');
    await mkdir(join(cwd, 'workspace'));
    process.chdir(join(cwd, 'workspace'));
    const result = await requestProposal({profile: profile(stub.endpoint('valid')), slice: slice(), requestId: 'request-valid'});
    assert.deepEqual(result, {ok: true, kind: 'proposal', proposal: {expectedRevision: 7, operations: [{kind: 'proposeScriptChunks', artifactId: 'script:selected', replacement: 'A clearer opening.'}], rationale: 'Tighten the first beat.'}});
    assert.equal(stub.observed.length, 1);
    assert.match(stub.observed[0].body, /Selected outline only/);
    assert.doesNotMatch(stub.observed[0].body, /PRIVATE_CONTEXT_SENTINEL|credentialRef|AGENTS/);
    assert.equal(stub.observed[0].requestId, 'request-valid');
  } finally { process.chdir(previousCwd); await rm(cwd, {recursive: true, force: true}); }
}));

for (const [scenario, expected] of [['malformed-json', 'malformed_response'], ['incomplete', 'incomplete_output'], ['oversized', 'response_too_large'], ['stale', 'invalid_proposal'], ['authority', 'invalid_proposal'], ['rate-limited', 'rate_limited']]) {
  test(`returns typed ${expected} for ${scenario}`, async () => withStub(async (stub) => {
    const result = await requestProposal({profile: profile(stub.endpoint(scenario)), slice: slice(), requestId: `request-${scenario}`});
    assert.equal(result.ok, false); assert.equal(result.kind, 'failure'); assert.equal(result.code, expected);
  }));
}

test('rejects an unselected existing artifact without a project write', async () => withStub(async (stub) => {
  const cwd = await mkdtemp(join(tmpdir(), 'takeform-provider-unselected-'));
  const project = join(cwd, 'project.json');
  try {
    await writeFile(project, '{"revision":7,"script":"original"}');
    const result = await requestProposal({profile: profile(stub.endpoint('unselected')), slice: slice(), requestId: 'request-unselected'});
    assert.equal(result.ok, false); assert.equal(result.kind, 'failure'); assert.equal(result.code, 'invalid_proposal');
    assert.equal(stub.observed.length, 1);
    assert.equal(await readFile(project, 'utf8'), '{"revision":7,"script":"original"}');
  } finally { await rm(cwd, {recursive: true, force: true}); }
}));

test('keeps refusal distinct from protocol failure', async () => withStub(async (stub) => {
  const result = await requestProposal({profile: profile(stub.endpoint('refusal')), slice: slice(), requestId: 'request-refusal'});
  assert.deepEqual(result, {ok: false, kind: 'refusal', reason: 'I cannot propose this.'});
}));

test('does not follow a redirect to another origin', async () => withStub(async (stub) => {
  const result = await requestProposal({profile: profile(stub.endpoint('redirect')), slice: slice(), requestId: 'request-redirect'});
  assert.equal(result.ok, false); assert.equal(result.kind, 'failure'); assert.equal(result.code, 'transport_error');
  assert.equal(stub.observed.length, 1);
  assert.equal(stub.redirected.length, 0);
}));

test('caller timeout cancels a delayed loopback request', async () => withStub(async (stub) => {
  const result = await requestProposal({profile: profile(stub.endpoint('delayed')), slice: slice(), requestId: 'request-cancel', timeoutMs: 25});
  assert.deepEqual(result, {ok: false, kind: 'failure', code: 'cancelled', detail: undefined});
}));

test('rejects unsupported or unsafe profiles before any send', async () => withStub(async (stub) => {
  for (const changes of [{capabilities: {}}, {accountKind: 'subscription'}, {endpoint: 'http://example.test/responses', localTestOnly: false}]) {
    const result = await requestProposal({profile: profile(stub.endpoint('valid'), changes), slice: slice(), requestId: 'request-rejected'});
    assert.equal(result.ok, false);
  }
  assert.equal(stub.observed.length, 0);
}));

test('rejects an oversized supplied context before any send', async () => withStub(async (stub) => {
  const result = await requestProposal({profile: profile(stub.endpoint('valid')), slice: {...slice(), artifacts: [{id: 'script:selected', content: 'x'.repeat(20 * 1024)}]}, requestId: 'request-big-context'});
  assert.equal(result.code, 'context_too_large'); assert.equal(stub.observed.length, 0);
}));

test('rejects raw path fields before any send', async () => withStub(async (stub) => {
  const invalidSlice = {...slice(), artifacts: [{id: 'script:selected', content: 'Selected outline only.', path: '/private/unselected'}]};
  const result = await requestProposal({profile: profile(stub.endpoint('valid')), slice: invalidSlice, requestId: 'request-path'});
  assert.equal(result.code, 'invalid_context'); assert.equal(stub.observed.length, 0);
}));
