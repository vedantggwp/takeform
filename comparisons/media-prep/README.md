# Shared HEIC media preparation

This unit converts the accepted M fixture's `lpMismatchStill` and `station` HEIC files into task-owned PNG derivatives. Frozen fixtures remain the source of truth. A derivative manifest binds each prepared file to its source ID and original SHA-256.

Run it with caller-supplied roots:

```sh
node comparisons/media-prep/media-prep.mjs \
  --fixture-root PATH_TO_ACCEPTED_FIXTURES \
  --derivative-root PATH_TO_OWNED_DERIVATIVES
```

`manifest.json` contains `schemaVersion`, fixture identity, actual ImageIO and host identity, settings and per-source records. Each record has original and prepared relative paths and hashes, source and output dimensions, primary-image identity, orientation treatment, alpha state, color-space/profile identity and a decoded-pixel digest.

Use the loader with the accepted snapshot, not an independently reconstructed source map:

```js
import {expectedOriginalsFromSnapshot, validateManifest} from './media-prep.mjs';

const entries = await validateManifest(manifest, {
  derivativeRoot,
  expectedOriginals: expectedOriginalsFromSnapshot(snapshot, 'M')
});
```

It rejects duplicate or unknown source IDs, original-hash mismatches, path escapes and prepared-hash mismatches. It does not rehash frozen originals at render time. The accepted snapshot has already bound those bytes.

The decoder reads the HEIC primary image through ImageIO, bakes EXIF orientation into pixels, writes a PNG with normalized orientation metadata and verifies decoded pixels, alpha state and color interpretation after reopening the PNG. It fails high-bit-depth input until an explicit HDR contract is approved. For an untagged decoded image, it explicitly treats the decoded result as sRGB instead of silently assigning a different working color space.
