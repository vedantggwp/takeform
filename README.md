# Takeform

A Mac-first studio for making videos with AI agents and repeatable channel formats.

Takeform includes a native development foundation for macOS. It provides an
ad-hoc-signed development app with native About and Settings surfaces, a build
doctor, and copied-bundle verification. Project editing, preview, rendering,
and export are not available in this slice.

The intended workflow connects audience and story, scripts, scenes, shots, asset sourcing or recording, rough cuts, sound, captions and export. Creators can start with an idea, a script or existing footage. A channel format preserves branding and production rules while leaving explicit slots for each episode.

The project is planned around reviewable issues and evidence from working prototypes. Follow the issues for current decisions and progress. The name is provisional.

## Development

Takeform requires macOS, Swift 6.3 or newer, and the system `codesign`,
`plutil`, and `ditto` tools. `ffmpeg` is reported as a later optional media
tool; the doctor never installs anything.

```sh
./scripts/takeform-doctor
swift test
swift build -c release
./scripts/package-dev-bundle
./scripts/verify-dev-bundle
```

The bundle script writes `dist/Takeform.app` by default and signs it ad hoc.
Pass a destination directory when a separate output location is useful:

```sh
./scripts/package-dev-bundle "/tmp/Takeform build"
./scripts/verify-dev-bundle "/tmp/Takeform build/Takeform.app"
```

`scripts/verify-dev-bundle` copies the selected app before checking its bundle
identity, icon, and signature. It does not prove Developer ID signing,
notarization, Gatekeeper acceptance, or visual app behavior.

The source has no third-party runtime dependencies. The application icon and
its source assets are original work in `design/identity`; see that directory's
README for its asset provenance. The [licence inventory](docs/license-inventory.md)
records the F1 bundle inputs. Takeform source is MIT-licensed under `LICENSE`.

## Product direction

The [architecture proposal](docs/architecture-proposal.md) recommends a native
SwiftUI app with an on-demand Swift service. This foundation supplies only the
native shell and development build path; project authority, rendering, and the
remaining creator workflow are separate work.

The typed storage and CLI boundary under development for the next foundation
increment is described in [project authority](docs/project-authority.md). It
does not add native project controls to this development app.

## Project management

GitHub issues own scope, dependencies and acceptance evidence. Each implementation PR links its issue and includes appropriate live verification. See [the roadmap](docs/roadmap.md).

## License

MIT for original project code and documentation. Any adopted third-party dependencies and assets retain their own terms.
