# Public MediaProbe tests

`swift test --filter TakeformMediaTests` generates cleared, synthetic media in a
unique temporary directory for each case. It neither reads
`TAKEFORM_FIXTURE_ROOT` nor depends on the working directory, local comparison
films, network downloads, personal media, or cloud storage. Each test defers
cleanup of its own root; a fixture-setup failure is a test failure, never a
skip.

The retained generator is
`Tests/TakeformMediaTests/SyntheticMediaFixtures.swift`. It uses only macOS
ImageIO, CoreGraphics, CoreVideo and AVFoundation. Its inputs are colored
pixels, silent samples, uneven presentation timestamps, and fixed test content
identifiers. It does not produce a user-facing import or a media acceptance
artifact.

| Behavior | Public synthetic evidence |
| --- | --- |
| Source identity and orientation | An 8-by-4 HEIC with ImageIO orientation 6; the test independently hashes it and checks encoded versus displayed dimensions. |
| Timing and transforms | A short H.264 MOV written at uneven rational times, plus an 8-by-4 rotated MOV. The probe must read real sample PTS and AVFoundation track transforms. |
| Audio facts | Silent mono 22,050 Hz PCM AIFF and stereo 48,000 Hz AAC M4A, verified through probed track format facts. |
| Duplicate and corrupt sources | A byte-for-byte copied PNG under a distinct name, and a malformed PNG with the typed per-file error. |
| Live Photo evidence | HEIC MakerApple key 17 and QuickTime content identifiers on separate MOVs: matching, mismatched, image/image wrong-kind, and absent-ID cases. Pairing uses the probe's independently read facts. |
| Cancellation and bounds | An in-flight hash-chunk gate followed by cancellation; a parseable H.264 MOV with a valid sparse `free` atom grows to more than 100 MiB logical size. The test observes the number of hash-chunk callbacks, stored PTS cap and total scanned PTS. |

The generated sparse padding measures logical file length, not allocated disk
blocks. The test requires AVFoundation to reopen the resulting MOV, so a
platform unable to write or parse a required synthetic format fails with its
typed fixture setup error.

Private comparison-film fixtures remain a separate opt-in integration evidence
path. They can establish behavior against the retained M/T/L media, but are not
required for a public clone's ordinary unit test suite and are never uploaded by
the source CI workflow.
