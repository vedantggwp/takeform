# Takeform native identity

The selected mark is **Three Cut Frame**. Three flat cuts make one stable editing frame: an opening cut, a right-hand hold and a lower-left close. It reads as a single silhouette before its three parts are noticed, so recognition does not rely on lighting, depth or a hidden letter.

## Decision

Two constructions were developed on the same 64-unit grid.

- `studies/concept-a-t-channel.svg` tests an explicit T channel. The channel is real, but the extra two short bars compete with it at 16 px. It remains a private study and has no production exports.
- `takeform-app-icon.svg` is selected. Its three cuts create an open frame with a 27-unit central field. At 16 px, the 8-unit minimum break becomes two pixels and the outer frame stays legible as one mark.

The master keeps enclosure, glyph and individual cuts as editable SVG groups. `takeform-app-icon-construction.svg` gives the simple 8-unit construction grid separately, so SVG renderers cannot leak the guide into production output. The mark deliberately makes no negative-T claim.

## Appearance and use

- `takeform-app-icon.svg` uses a warm paper enclosure, graphite frame and a single vermilion opening cut. Vermilion is brand identification only; do not reuse it for error, destructive or recording states in the app.
- `takeform-app-icon-dark.svg` keeps geometry unchanged and reverses the frame for a dark enclosure.
- `takeform-app-icon-mono.svg` is a one-color, transparent-background foreground suitable for tint/mono treatment. It is not an Icon Composer annotation file.
- The system applies the macOS icon mask. Do not add an extra rounded-rectangle mask around this artwork.
- No wordmark or external font is included. Product UI can use the platform system type; a distinct wordmark needs a separate lettering and clearance decision.

## Exports

Run these from this directory:

```sh
./build-iconset.sh
./build-appearance-variants.sh
./build-contact-sheet.sh
```

This creates a conventional macOS `.iconset` and `Takeform.icns`, 1024px Default/Dark/Mono PNGs, and `contact-sheet-actual-size.png`. The contact sheet retains 16, 24, 32, 64 and 128 pixel samples at those exact raster sizes; it has no proxy size labels. Then run `./verify-exports.sh` to decode the ICNS through Apple’s `iconutil` and check every expected pixel size. Current macOS exposes the legacy 64 px `icp6` ICNS payload as a 48 px decoded representation; the source iconset still includes the original 64 px PNG.

`magick` is the only non-system build dependency. The render commands strip encoder metadata so fresh exports are byte-reproducible. `python3`, `sips` and `iconutil` are supplied by macOS. On this macOS 26.6.2 host, `iconutil` can decode ICNS but rejects every iconset-to-ICNS conversion tested, including a clean iconset freshly decoded from Apple’s Terminal.icns. `pack-icns.py` writes the documented PNG ICNS chunks from the primary iconset instead; `verify-exports.sh` uses the Apple decoder to check that result. This is a host-workaround, not a claim about other Macs. The package does not include an `.icon` file because Icon Composer was not installed or verified in this task. Apple’s current documentation says Icon Composer supports Default, Dark and Mono variants, but these SVG variants have not been imported into it or into an app bundle.

## Sources and limits

All paths and colors are original work in this directory. No stock, generated image, external font, third-party artwork or private study image is included. This is a visual/asset delivery, not trademark clearance, installed-app verification or an Icon Composer fidelity claim.
