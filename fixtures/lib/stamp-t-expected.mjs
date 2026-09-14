#!/usr/bin/env node
"use strict";

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.argv[2];
if (!dir) {
  console.error("usage: stamp-t-expected.mjs <T fixture dir>");
  process.exit(2);
}

const take1 = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
const take2 = JSON.parse(readFileSync(join(dir, "words-take2.json"), "utf8"));
const take1Audio = JSON.parse(readFileSync(join(dir, "audio-take1.json"), "utf8"));
const take2Audio = JSON.parse(readFileSync(join(dir, "audio-take2.json"), "utf8"));
const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));

function norm(text) {
  return String(text).toLowerCase().replace(/[^a-z]/g, "");
}

function secondsOf(rational) {
  return rational.ticks / rational.timescale;
}

function asRational(seconds, timescale = 1000) {
  return { ticks: Math.round(seconds * timescale), timescale };
}

function word(words, text, after = 0) {
  const found = words.find((candidate) =>
    candidate.sourceStartSeconds + 1e-9 >= after && norm(candidate.text) === norm(text)
  );
  if (!found || typeof found.id !== "string" || found.id.length === 0) {
    throw new Error("measured word not found with an id: " + text);
  }
  return found;
}

function phrase(words, startText, endText, after = 0) {
  const first = word(words, startText, after);
  const start = words.indexOf(first);
  const end = words.findIndex((candidate, index) => index >= start && norm(candidate.text) === norm(endText));
  if (end < start) throw new Error("phrase end not found: " + endText);
  const selected = words.slice(start, end + 1);
  return {
    words: selected,
    start: selected[0].sourceStartSeconds,
    end: selected[selected.length - 1].sourceEndSeconds
  };
}

function correctionFor(sourceId, words, text, after, toText, occurrenceIds) {
  const selected = word(words, text, after);
  return {
    sourceId,
    wordId: selected.id,
    fromText: selected.text,
    toText,
    timingUnchanged: true,
    occurrenceIds
  };
}

function cutByOccurrence(occurrenceId) {
  const cut = manifest.canonicalPlan.cutList.find((candidate) => candidate.occurrenceId === occurrenceId);
  if (!cut) throw new Error("cut not found for occurrence: " + occurrenceId);
  return cut;
}

function mapThroughOccurrence(sourceId, occurrenceId, sourceStart, sourceEnd) {
  const cut = cutByOccurrence(occurrenceId);
  if (cut.takeSourceId !== sourceId) {
    throw new Error("occurrence " + occurrenceId + " does not use " + sourceId);
  }
  const cutStart = secondsOf(cut.sourceRange.start);
  const cutEnd = cutStart + secondsOf(cut.sourceRange.duration);
  if (sourceStart + 1e-6 < cutStart || sourceEnd - 1e-6 > cutEnd) {
    throw new Error("occurrence " + occurrenceId + " does not contain the source phrase");
  }
  const outputStart = secondsOf(cut.outputRange.start);
  const factor = cut.retimeFactor ? cut.retimeFactor.num / cut.retimeFactor.den : 1;
  return {
    start: outputStart + (sourceStart - cutStart) / factor,
    duration: (sourceEnd - sourceStart) / factor
  };
}

function correctedText(words, sourceId, occurrenceId, corrections) {
  const replacements = new Map(
    corrections
      .filter((correction) => correction.sourceId === sourceId && correction.occurrenceIds.includes(occurrenceId))
      .map((correction) => [correction.wordId, correction.toText])
  );
  return words.map((candidate) => replacements.get(candidate.id) ?? candidate.text).join(" ");
}

const wordsBySource = { take1: take1.words, take2: take2.words };
for (const [sourceId, receipt] of Object.entries({ take1, take2 })) {
  if (!Array.isArray(receipt.words) || receipt.words.length === 0) {
    throw new Error(sourceId + " has no measured words");
  }
}

function gcd(a, b) {
  return b === 0 ? a : gcd(b, a % b);
}

function measuredRange(audio, startSeconds, outputSeconds) {
  const startFrame = Math.round(startSeconds * audio.sampleRate);
  const durationFrames = audio.finalizedFrames - startFrame;
  if (!Number.isInteger(audio.sampleRate) || !Number.isInteger(audio.finalizedFrames) || startFrame < 0 || durationFrames <= 0) {
    throw new Error("speech receipt cannot define an exact dialogue range");
  }
  const divisor = gcd(durationFrames, Math.round(outputSeconds * audio.sampleRate));
  return {
    start: { ticks: startFrame, timescale: audio.sampleRate },
    duration: { ticks: durationFrames, timescale: audio.sampleRate },
    retimeFactor: { num: durationFrames / divisor, den: Math.round(outputSeconds * audio.sampleRate) / divisor }
  };
}

const take2A = measuredRange(take2Audio, 10, 48);
const take1B = measuredRange(take1Audio, 34, 10);
const take2B = measuredRange(take2Audio, 20, 20);
const alignedRanges = new Map([
  ["oTake2A", take2A], ["oDlg2A", take2A],
  ["oTake1B", take1B], ["oDlg1B", take1B],
  ["oTake2B", take2B], ["oDlg2B", take2B]
]);
for (const occurrence of manifest.canonicalPlan.occurrences) {
  const aligned = alignedRanges.get(occurrence.id);
  if (aligned) {
    occurrence.sourceRange = { start: aligned.start, duration: aligned.duration };
    occurrence.retimeFactor = aligned.retimeFactor;
  }
}
manifest.expected.sourceToOutput = manifest.canonicalPlan.occurrences.map((occurrence) => ({
  occurrenceId: occurrence.id,
  sourceId: occurrence.sourceId,
  sourceRange: occurrence.sourceRange,
  outputRange: occurrence.outputRange
}));

manifest.canonicalPlan.cutList = manifest.canonicalPlan.occurrences
  .filter((occurrence) => occurrence.role === "dialogue")
  .map((occurrence) => ({
    occurrenceId: occurrence.id,
    takeSourceId: occurrence.sourceId,
    sourceRange: occurrence.sourceRange,
    outputRange: occurrence.outputRange,
    ...(occurrence.retimeFactor.num === 1 && occurrence.retimeFactor.den === 1 ? {} : { retimeFactor: occurrence.retimeFactor })
  }));

const corrections = [
  correctionFor("take1", take1.words, "last", 0, "final", ["oDlg1A"]),
  correctionFor("take2", take2.words, "operator", 10, "creator", ["oDlg2A"]),
  correctionFor("take2", take2.words, "Captions", 10, "Subtitles", ["oDlg2A"]),
  correctionFor("take2", take2.words, "Chapter", 20, "Section", ["oDlg2A", "oDlg2B"]),
  correctionFor("take1", take1.words, "same", 34, "shared", ["oDlg1B"])
];
manifest.canonicalPlan.wordCorrections = corrections;

const captionSpecs = [
  { sourceId: "take1", occurrenceId: "oDlg1A", start: "Hold", end: "thought", after: 0 },
  { sourceId: "take2", occurrenceId: "oDlg2A", start: "operator", end: "cut", after: 10 },
  { sourceId: "take2", occurrenceId: "oDlg2A", start: "Captions", end: "map", after: 10 },
  { sourceId: "take2", occurrenceId: "oDlg2A", start: "Chapter", end: "segment", after: 20 },
  { sourceId: "take2", occurrenceId: "oDlg2B", start: "Chapter", end: "segment", after: 20 },
  { sourceId: "take1", occurrenceId: "oDlg1B", start: "same", end: "share", after: 34 }
];

manifest.expected.captions = captionSpecs.map((spec) => {
  const selected = phrase(wordsBySource[spec.sourceId], spec.start, spec.end, spec.after);
  const mapped = mapThroughOccurrence(spec.sourceId, spec.occurrenceId, selected.start, selected.end);
  return {
    text: correctedText(selected.words, spec.sourceId, spec.occurrenceId, corrections),
    sourceRange: {
      start: asRational(selected.start),
      duration: asRational(selected.end - selected.start)
    },
    outputRange: {
      start: asRational(mapped.start),
      duration: asRational(mapped.duration)
    },
    takeSourceId: spec.sourceId,
    occurrenceId: spec.occurrenceId,
    straddlesCut: false
  };
});

writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log("stamped T captions and source-keyed word corrections");
