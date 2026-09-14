#!/usr/bin/env node
"use strict";

import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const fixture = process.argv[2];
if (!fixture) throw new Error("usage: verify-t-contract-regression.mjs <T fixture dir>");
const verifier = join(new URL("..", import.meta.url).pathname, "lib/verify-t-contract.mjs");

function prepare() {
  const dir = mkdtempSync(join(tmpdir(), "takeform-t-contract-"));
  for (const name of ["manifest.json", "words-take1.json", "words-take2.json", "audio-take1.json", "audio-take2.json", "script-take1.txt", "script-take2.txt"]) {
    cpSync(join(fixture, name), join(dir, name));
  }
  symlinkSync(realpathSync(join(fixture, "media")), join(dir, "media"));
  return dir;
}

function expectFail(dir, label) {
  try {
    execFileSync(process.execPath, [verifier, dir], { encoding: "utf8", stdio: "pipe" });
  } catch (error) {
    const output = String(error.stderr);
    if (output.includes(label)) return;
    throw new Error("mutation failed for the wrong reason: " + output);
  }
  throw new Error("mutation unexpectedly passed: " + label);
}

execFileSync(process.execPath, [verifier, fixture], { stdio: "inherit" });

{
  const dir = prepare();
  const audio = JSON.parse(readFileSync(join(dir, "audio-take1.json"), "utf8"));
  audio.finalizedFrames += 1;
  writeFileSync(join(dir, "audio-take1.json"), JSON.stringify(audio));
  expectFail(dir, "audio receipt frame counts disagree with ffprobe");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].sourceEndSeconds = words.words[0].sourceStartSeconds;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word has non-finite or invalid timing");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].sourceStartSeconds = null;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word has non-finite or invalid timing");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[1].sourceStartSeconds = words.words[0].sourceStartSeconds;
  words.words[1].rawStartSeconds = words.words[0].sourceStartSeconds;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word crosses its utterance origin or overlaps");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].acousticTailEndFrame = Math.round(words.words[0].sourceStartSeconds * words.sampleRate);
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word has no active waveform support");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.canonicalPlan.wordCorrections[0].fromText = "not-the-source-word";
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "correction does not identify its source word");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.canonicalPlan.wordCorrections[0].sourceId = "take2";
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "correction does not identify its source word");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.canonicalPlan.wordCorrections[0].wordId = "missing-word";
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "correction does not identify its source word");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.canonicalPlan.wordCorrections[0].occurrenceIds = ["missing-occurrence"];
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "correction selects an unknown occurrence");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.canonicalPlan.wordCorrections[0].occurrenceIds = [];
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "correction does not select a unique occurrence");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.expected.captions[0].outputRange.start.ticks += 1000;
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "caption output start");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.expected.captions[0].sourceRange.duration.ticks += 100000;
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "source range does not belong to occurrence");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.expected.sourceToOutput[0].sourceRange.start.ticks += 1;
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "source-to-output mapping does not preserve occurrence");
}

console.log("ok T contract negative mutations");
