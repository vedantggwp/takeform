#!/usr/bin/env node
"use strict";

import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { normalizeCtcText } from "../lib/verify-t-contract.mjs";

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
  const normalized = normalizeCtcText("Hold, hold! Don't cut two-second words.");
  if (normalized.symbols.join("") !== "HOLD|HOLD|DON'T|CUT|TWO|SECOND|WORDS") throw new Error("CTC normalizer changed its symbol contract");
  if (JSON.stringify(normalized.parts.map((part) => [part.text, part.location, part.length, part.charStart, part.charEnd])) !== JSON.stringify([
    ["Hold,", 0, 5, 0, 4], ["hold!", 6, 5, 5, 9], ["Don't", 12, 5, 10, 15],
    ["cut", 18, 3, 16, 19], ["two-second", 22, 10, 20, 30], ["words.", 33, 6, 31, 36]
  ])) throw new Error("CTC normalizer changed its positional word mapping");
  if (JSON.stringify(normalized.events.map((event) => event.character)) !== JSON.stringify([",", "!", "-", "."])) throw new Error("CTC normalizer changed punctuation handling");
  for (const text of ["H0ld", "Hold🙂", "Hold | thought", "--", ""]) {
    try {
      normalizeCtcText(text);
    } catch {
      continue;
    }
    throw new Error("CTC normalizer accepted unsupported input: " + JSON.stringify(text));
  }
}

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
  words.words[2].sourceStartSeconds = words.words[1].sourceEndSeconds - 0.01;
  words.words[2].rawStartSeconds = words.words[2].sourceStartSeconds;
  words.words[1].acousticTailEndFrame = Math.round(words.words[2].sourceStartSeconds * words.sampleRate);
  words.words[1].acousticTailEndSeconds = words.words[1].acousticTailEndFrame / words.sampleRate;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word crosses its utterance origin or overlaps");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].acousticTailEndFrame = Math.round(words.words[0].sourceStartSeconds * words.sampleRate) - 1;
  words.words[0].acousticTailEndSeconds = words.words[0].acousticTailEndFrame / words.sampleRate;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word has an invalid acoustic-tail estimate");
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

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.canonicalPlan.occurrences.find((row) => row.id === "oDlg2A").retimeFactor = { num: 9, den: 1 };
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "occurrence oDlg2A output duration contradicts its retime factor");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.canonicalPlan.cutList.find((row) => row.occurrenceId === "oDlg2A").retimeFactor = { num: 9, den: 1 };
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "cut list retime factor does not preserve occurrence oDlg2A");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.alignment.modelSha256 = "0".repeat(64);
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "receipt lacks a concrete CTC aligner identity");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.alignment.acousticEvidence = [];
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "acoustic evidence does not identify each utterance exactly once");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].tokens = [999];
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word tokens do not match retained CTC rows");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].characterRange.location = 99999;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word character range does not select its original lexeme");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.alignment.acousticEvidence[0].ctcTokens[0].symbol = "Z";
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "retained CTC token does not match the pinned label dictionary");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.alignment.acousticEvidence[0].ctcTokens[0].token = 999;
  words.words[0].tokens[0] = 999;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "retained CTC token does not match the pinned label dictionary");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  const evidence = words.alignment.acousticEvidence[0];
  [evidence.ctcTokens[0], evidence.ctcTokens[1]] = [evidence.ctcTokens[1], evidence.ctcTokens[0]];
  [words.words[0].tokens[0], words.words[0].tokens[1]] = [words.words[0].tokens[1], words.words[0].tokens[0]];
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "retained CTC rows are not chronological and non-overlapping");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.alignment.acousticEvidence[0].normalizedTranscript = "BOGUS";
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "normalized transcript differs from its utterance origin");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  const word = words.words[39];
  const evidence = words.alignment.acousticEvidence.find((row) => row.utteranceId === word.utteranceId);
  const utterance = JSON.parse(readFileSync(join(dir, "audio-take1.json"), "utf8")).utterances.find((row) => row.id === word.utteranceId);
  word.ctcEmissionStart -= 1;
  word.sourceStartSeconds = utterance.startFrame / words.sampleRate + word.ctcEmissionStart * evidence.secondsPerEmissionFrame;
  word.rawStartSeconds = word.sourceStartSeconds;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word emission endpoints do not match its normalized token rows");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  const word = words.words[0];
  const evidence = words.alignment.acousticEvidence[0];
  const utterance = JSON.parse(readFileSync(join(dir, "audio-take1.json"), "utf8")).utterances[0];
  word.ctcEmissionEnd += 1;
  word.sourceEndSeconds = utterance.startFrame / words.sampleRate + word.ctcEmissionEnd * evidence.secondsPerEmissionFrame;
  word.rawEndSeconds = word.sourceEndSeconds;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word emission endpoints do not match its normalized token rows");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].characterRange = structuredClone(words.words[4].characterRange);
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word character range does not select its original lexeme");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].probability = -1;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "word probability does not match retained CTC rows");
}

{
  const dir = prepare();
  const words = JSON.parse(readFileSync(join(dir, "words-take1.json"), "utf8"));
  words.words[0].acousticTailEndSeconds = 40;
  writeFileSync(join(dir, "words-take1.json"), JSON.stringify(words));
  expectFail(dir, "acoustic tail seconds");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.expected.captions[0].text = "Hold the last thought. final";
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "caption text does not reconstruct from its source words");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.expected.captions.shift();
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "correction must apply exactly once in selected output captions");
}

{
  const dir = prepare();
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.expected.captions.push(structuredClone(manifest.expected.captions[0]));
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  expectFail(dir, "correction must apply exactly once in selected output captions");
}

console.log("ok T contract negative mutations");
