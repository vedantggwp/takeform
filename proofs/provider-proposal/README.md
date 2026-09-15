# Provider proposal proof

This disposable proof answers one question: can Takeform send a host-built revision slice to a direct structured-response boundary and receive only a typed, non-authoritative proposal?

Run `npm run proof` with Node 22 or newer. It starts an owned loopback HTTP stub, runs the actual transport cases, and closes the server. It does not load files from the working directory, contact a provider, use a credential, call a model, mutate a project, or retry a paid outcome.

The only accepted transport is a declared `openai-compatible` profile with structured-proposal capability, API account kind, model, endpoint, and opaque credential reference. A remote endpoint must be HTTPS. HTTP is permitted only for an explicit loopback test profile. Redirects fail instead of forwarding a request to another origin. A ChatGPT or Codex subscription is rejected; it is not treated as API credit or zero usage.

The request uses the documented OpenAI-compatible structured-response shape: `store: false`, one host-built input message, and strict `json_schema` output. The profile credential reference is deliberately never sent. Existing-artifact operations must name an ID in the supplied slice. The response can produce a typed proposal, typed protocol failure, or usable refusal. It cannot apply a command or write a project.

This is evidence for the direct structured-proposal boundary only. It does not establish a live provider’s API compatibility, authentication, billing, data-destination policy, native app integration, or a complete creator workflow.
