# TakeformMedia

`TakeformMedia` reads source metadata without modifying source files. A result
records byte identity, container/stream facts, rational clocks, measured video
presentation timestamps, image orientation, audio format, and the provenance of
any Live Photo content identifier.

It does not import, copy, deduplicate, pair by filenames, select assets, or
make timeline decisions. `hasSameBytes` only reports exact source-byte equality.
`pairLivePhoto` confirms a pair only when both measured content identifiers
agree; missing or disagreeing identifiers remain unavailable or candidates.

The probe hashes through fixed-size chunks and retains a bounded prefix of
presentation timestamps while scanning samples. Its measurement records the
configured bounds and elapsed time; it is evidence about the probe run, not a
visual-quality or audio-quality assessment.
