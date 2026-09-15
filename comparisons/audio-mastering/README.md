# Shared audio mastering

`masterArtifact()` is renderer-neutral post-mix mastering. It keeps the raw producer file, uses FFmpeg's documented two-pass `loudnorm` measurements, stream-copies video, and publishes only a fully re-measured temporary output. The caller supplies the raw/output paths, explicit FFmpeg/FFprobe paths, the frozen frame-state targets, codec policy, timing bound, and four named video sample frames.

The stage records raw/mastered hashes, stream identities, decoded RGBA sample hashes, EBU R128 JSON, exact commands, target checks, timing/priming bounds, and cleanup in an attempt-owned terminal receipt. It rejects missing, streamless, silent, non-finite, or overwritten inputs. It cannot repair producer provenance or establish listening quality.

FFmpeg documents `loudnorm` two-pass inputs and JSON measurements at <https://ffmpeg.org/ffmpeg-filters.html#loudnorm>.
