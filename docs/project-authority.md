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

Machine bindings and grants are kept in the caller-provided machine-local
runtime directory. They are not portable package data. A second location with
the same project UUID needs an explicit rebind; rebind invalidates that
project's local grants, so a CLI must be paired again. A newer schema, a
missing inventoried object, database corruption, projection drift, and a copy
decision are distinct outcomes.

`TakeformAuthorityService` accepts only an already-authorized typed command.
`takeform` relays that same command to the service selected by
`TAKEFORM_AUTHORITY_SERVICE`; it does not import or open SQLite. Authorization
and scope are checked before a command-result lookup. An authorized replay of
the same command ID and request returns the saved result. Reuse with a
different request is rejected, and a stale revision returns the committed
revision.

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
disposable machine-local grant, then runs the real service and CLI. Crash-
barrier evidence and native creator interaction evidence remain separate
acceptance work; no fault switch is present in the app, CLI, or authority
service.
