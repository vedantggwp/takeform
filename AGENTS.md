# Takeform development guide

Use the documented commands from the repository root:

```sh
./scripts/takeform-doctor
swift test
swift build -c release
./scripts/package-dev-bundle
./scripts/verify-dev-bundle
```

`Sources/TakeformApp` owns the native shell and its accurate present-tense
product copy. `Sources/TakeformSupport` owns portable build-tool and bundle
identity validation. Keep project authority, rendering, providers, media work,
downloads, and editor actions out of this foundation slice.

For a change to the native shell, retain focused Swift tests, a release build,
and copied-bundle verification. Reviewers separately inspect the real app for
menus, settings, accessibility, sizing, and appearance. Do not claim that a
source check proves those visible behaviors or distribution notarization.
