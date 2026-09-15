const MAX_CONTEXT_BYTES = 16 * 1024;
const MAX_RESPONSE_BYTES = 32 * 1024;

export function failure(code, detail) {
  return {ok: false, kind: 'failure', code, detail};
}

function bytes(value) {
  return Buffer.byteLength(JSON.stringify(value));
}

function isLoopback(url) {
  return ['127.0.0.1', '::1', 'localhost'].includes(url.hostname);
}

export function validateProfile(profile) {
  if (!profile || profile.transport !== 'openai-compatible') return failure('unsupported_transport');
  if (!profile.endpoint || !profile.model || !profile.accountKind) return failure('missing_profile_setting');
  if (profile.accountKind !== 'api') return failure('unsupported_account_kind');
  if (profile.capabilities?.structuredProposal !== true) return failure('unsupported_capability');
  let url;
  try { url = new URL(profile.endpoint); } catch { return failure('invalid_endpoint'); }
  if (url.protocol !== 'https:' && !(profile.localTestOnly === true && url.protocol === 'http:' && isLoopback(url))) {
    return failure('insecure_endpoint');
  }
  return {ok: true, url};
}

export function validateSlice(slice) {
  if (!slice || !Number.isInteger(slice.revision) || slice.revision < 1) return failure('invalid_context');
  if (!Array.isArray(slice.artifacts) || slice.artifacts.length === 0 || !Array.isArray(slice.commandSchema)) return failure('invalid_context');
  for (const artifact of slice.artifacts) {
    if (!artifact || typeof artifact.id !== 'string' || typeof artifact.content !== 'string' || Object.keys(artifact).some((key) => !['id', 'content'].includes(key))) {
      return failure('invalid_context');
    }
  }
  if (bytes(slice) > MAX_CONTEXT_BYTES) return failure('context_too_large');
  return {ok: true};
}

function schema() {
  return {
    type: 'object', additionalProperties: false,
    required: ['expectedRevision', 'operations', 'rationale'],
    properties: {
      expectedRevision: {type: 'integer', minimum: 1},
      rationale: {type: 'string', minLength: 1},
      operations: {
        type: 'array', minItems: 1,
        items: {
          type: 'object', additionalProperties: false,
          required: ['kind', 'artifactId', 'replacement'],
          properties: {
            kind: {const: 'proposeScriptChunks'}, artifactId: {type: 'string'}, replacement: {type: 'string', minLength: 1}
          }
        }
      }
    }
  };
}

export function requestBody(profile, slice, requestId) {
  return {
    model: profile.model,
    store: false,
    input: [{role: 'user', content: [{type: 'input_text', text: JSON.stringify({context: slice, commandSchema: slice.commandSchema})}]}],
    text: {format: {type: 'json_schema', name: 'takeform_proposal', strict: true, schema: schema()}},
    metadata: {takeform_request_id: requestId}
  };
}

function parseEnvelope(value, revision, selectedArtifactIds) {
  if (!value || typeof value !== 'object' || Object.keys(value).some((key) => !['expectedRevision', 'operations', 'rationale'].includes(key))) return failure('invalid_proposal');
  if (value.expectedRevision !== revision || !Array.isArray(value.operations) || typeof value.rationale !== 'string' || value.rationale.length === 0) return failure('invalid_proposal');
  for (const operation of value.operations) {
    if (!operation || Object.keys(operation).some((key) => !['kind', 'artifactId', 'replacement'].includes(key)) || operation.kind !== 'proposeScriptChunks' || typeof operation.artifactId !== 'string' || !selectedArtifactIds.has(operation.artifactId) || typeof operation.replacement !== 'string' || operation.replacement.trim() === '') {
      return failure('invalid_proposal');
    }
  }
  return {ok: true, kind: 'proposal', proposal: value};
}

function outputText(response) {
  for (const item of response?.output ?? []) {
    for (const content of item.content ?? []) {
      if (content.type === 'refusal') return {refusal: content.refusal || 'provider refused'};
      if (content.type === 'output_text') return {text: content.text};
    }
  }
  return null;
}

export async function requestProposal({profile, slice, requestId, timeoutMs = 500, fetchImpl = fetch}) {
  const profileResult = validateProfile(profile);
  if (!profileResult.ok) return profileResult;
  const sliceResult = validateSlice(slice);
  if (!sliceResult.ok) return sliceResult;
  if (!requestId || typeof requestId !== 'string') return failure('missing_request_identity');
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(profileResult.url, {
      method: 'POST', signal: controller.signal, redirect: 'error',
      headers: {'content-type': 'application/json', 'x-takeform-request-id': requestId},
      body: JSON.stringify(requestBody(profile, slice, requestId))
    });
    if (response.status === 429) return failure('rate_limited');
    if (!response.ok) return failure('http_error', String(response.status));
    const text = await response.text();
    if (Buffer.byteLength(text) > MAX_RESPONSE_BYTES) return failure('response_too_large');
    let decoded;
    try { decoded = JSON.parse(text); } catch { return failure('malformed_response'); }
    if (decoded.status === 'incomplete') return failure('incomplete_output', decoded.incomplete_details?.reason || 'unknown');
    const output = outputText(decoded);
    if (output?.refusal) return {ok: false, kind: 'refusal', reason: output.refusal};
    if (!output || typeof output.text !== 'string') return failure('missing_output');
    let proposal;
    try { proposal = JSON.parse(output.text); } catch { return failure('malformed_proposal'); }
    return parseEnvelope(proposal, slice.revision, new Set(slice.artifacts.map((artifact) => artifact.id)));
  } catch (error) {
    if (error?.name === 'AbortError') return failure('cancelled');
    return failure('transport_error', error?.name || 'unknown');
  } finally {
    clearTimeout(timeout);
  }
}
