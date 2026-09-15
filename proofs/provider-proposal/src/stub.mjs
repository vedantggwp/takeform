import http from 'node:http';

const forbidden = ['PRIVATE_CONTEXT_SENTINEL', 'ancestor AGENTS', '/Users/', 'credentialRef'];

function responseFor(scenario, revision) {
  const valid = {expectedRevision: revision, operations: [{kind: 'proposeScriptChunks', artifactId: 'script:selected', replacement: 'A clearer opening.'}], rationale: 'Tighten the first beat.'};
  const text = (value) => JSON.stringify({output: [{type: 'message', content: [{type: 'output_text', text: JSON.stringify(value)}]}]});
  if (scenario === 'valid') return [200, text(valid)];
  if (scenario === 'malformed-json') return [200, '{'];
  if (scenario === 'refusal') return [200, JSON.stringify({output: [{type: 'message', content: [{type: 'refusal', refusal: 'I cannot propose this.'}]}]})];
  if (scenario === 'incomplete') return [200, JSON.stringify({status: 'incomplete', incomplete_details: {reason: 'max_output_tokens'}})];
  if (scenario === 'oversized') return [200, JSON.stringify({output: [{type: 'message', content: [{type: 'output_text', text: 'x'.repeat(40 * 1024)}]}]})];
  if (scenario === 'stale') return [200, text({...valid, expectedRevision: revision - 1})];
  if (scenario === 'unselected') return [200, text({...valid, operations: [{...valid.operations[0], artifactId: 'script:unselected'}]})];
  if (scenario === 'authority') return [200, text({...valid, author: 'model', mutation: 'applyProjectWrite'})];
  return [404, JSON.stringify({error: 'unknown scenario'})];
}

export async function startStub() {
  const observed = [];
  const redirected = [];
  const redirectTarget = http.createServer((req, res) => {
    redirected.push({url: req.url, method: req.method});
    res.writeHead(200, {'content-type': 'application/json'});
    res.end(JSON.stringify({error: 'redirect target reached'}));
  });
  await new Promise((resolve) => redirectTarget.listen(0, '127.0.0.1', resolve));
  const redirectPort = redirectTarget.address().port;
  const server = http.createServer(async (req, res) => {
    const body = await new Promise((resolve) => {
      let value = '';
      req.setEncoding('utf8');
      req.on('data', (chunk) => { value += chunk; });
      req.on('end', () => resolve(value));
    });
    observed.push({url: req.url, requestId: req.headers['x-takeform-request-id'], body});
    if (forbidden.some((sentinel) => body.includes(sentinel))) {
      res.writeHead(400, {'content-type': 'application/json'});
      res.end(JSON.stringify({error: 'forbidden context'}));
      return;
    }
    const scenario = req.url.slice(1);
    if (scenario === 'redirect') { res.writeHead(302, {location: `http://127.0.0.1:${redirectPort}/capture`}); res.end(); return; }
    if (scenario === 'rate-limited') { res.writeHead(429, {'content-type': 'application/json'}); res.end(JSON.stringify({error: 'rate limited'})); return; }
    if (scenario === 'delayed') { await new Promise((resolve) => setTimeout(resolve, 250)); res.writeHead(200, {'content-type': 'application/json'}); res.end(responseFor('valid', 7)[1]); return; }
    let revision = 7;
    try { revision = JSON.parse(JSON.parse(body).input[0].content[0].text).context.revision; } catch { /* adapter owns request validation */ }
    const [status, payload] = responseFor(scenario, revision);
    res.writeHead(status, {'content-type': 'application/json'});
    res.end(payload);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const {port} = server.address();
  return {
    observed, redirected, endpoint: (scenario) => `http://127.0.0.1:${port}/${scenario}`,
    close: async () => {
      await Promise.all([new Promise((resolve) => server.close(resolve)), new Promise((resolve) => redirectTarget.close(resolve))]);
    }
  };
}
