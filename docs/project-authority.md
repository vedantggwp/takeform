# Project authority boundary

`TakeformAuthority` is the sole writer for one open `.takeform` package. It
keeps the durable document, revision, command results, and undo history in
`.takeform/project.sqlite`; SQLite runs in WAL mode and each accepted command
commits its document change and durable result in one transaction.

The package also contains `.takeform/manifest.json`, with the project UUID,
schema, and relative immutable-object inventory, plus `projection.json`. This
slice has no separate immutable project objects yet, so that inventory starts
empty. The projection
is an inspectable export of the authority document. Opening a package reports
whether it matches; it never becomes a second writer or resets the database.

Machine bindings and token digests live in the user Application Support
directory. A paired CLI keeps its raw token in its own login Keychain item;
the service receives that token on standard input and compares only its digest.
Service and CLI arguments cannot select either store. A second location with
the same project UUID needs an explicit rebind; rebind increments the epoch and
invalidates that project's prior grant digest, so a CLI must be paired again. A
newer schema, a missing inventoried object, database corruption, projection
drift, and a copy decision are distinct outcomes.

`TakeformAuthorityService` accepts only an already-authorized typed command.
`takeform` relays that same command only to its bundled sibling authority
service; it does not import or open SQLite. Authorization and scope are checked
before a command-result lookup. An authorized replay of
the same command ID and request returns the saved result. Reuse with a
different expected revision or request is rejected, and a stale revision
returns the committed revision.

The app-owned pairing flow imports an issued raw token into the CLI with
`takeform import-paired-credential <grant-id>` over standard input. Importing a
credential cannot issue a grant: the service still requires a current
app-storage digest, scope, expiry, revocation state and authority epoch. The
CLI uses bounded background Keychain calls and returns a typed unavailable or
store failure instead of writing a plaintext fallback.

The grant issuer used by the process integration test is test-only. Neither
shipping executable can mint creator authority, and this boundary does not
claim that a native app owns the service or exposes project controls. Those
native controls and pairing lifecycle belong to F3.

Run the focused source and process checks with:

```sh
swift test --filter TakeformAuthorityTests
swift run TakeformAuthorityHarness .build/debug/TakeformAuthorityService .build/debug/takeform
```

`TakeformAuthorityHarness` is an unshipped executable target. It seeds only a
disposable app-storage digest, then has the real CLI import its paired
credential and runs the real service and CLI. It also measures 20 opens and 20
paired CLI commands. Crash-
barrier evidence comes from the separately built `TakeformAuthorityFaultHarness`:
in debug builds it drives the real service through private SQLite hooks
immediately before and after `COMMIT`. Those hooks compile out of release
targets and are absent from the app and CLI. Native creator interaction
evidence remains separate acceptance work.
