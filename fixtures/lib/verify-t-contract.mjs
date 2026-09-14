#!/usr/bin/env node
"use strict";

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const EPSILON = 0.0011;
const PROBABILITY_EPSILON = 1e-9;
const PINNED_MODEL_SHA256 = "488fd4f16de84438ffc945334278c1b9fb9b7159a806c1080b16111a958c945d";
const WAV2VEC2_ASR_BASE_960H_LABELS = Object.freeze([
  "-", "|", "E", "T", "A", "O", "N", "I", "H", "S", "R", "D", "L", "U", "M",
  "W", "C", "F", "G", "Y", "P", "B", "V", "K", "'", "X", "J", "Q", "Z"
]);

function fail(message) {
  throw new Error(message);
}

function secondsOf(rational) {
  return rational.ticks / rational.timescale;
}

function rangeOf(range) {
  const start = secondsOf(range.start);
  return { start, end: start + secondsOf(range.duration) };
}

function contains(outer, inner) {
  return inner.start + EPSILON >= outer.start && inner.end - EPSILON <= outer.end;
}

function close(actual, expected, label) {
  if (!Number.isFinite(actual) || Math.abs(actual - expected) > EPSILON) {
    fail(label + " is " + actual + ", expected " + expected);
  }
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function audioFacts(path) {
  const probe = JSON.parse(execFileSync("ffprobe", [
    "-v", "error", "-select_streams", "a:0", "-show_entries",
    "stream=sample_rate,duration_ts,time_base,duration", "-of", "json", path
  ], { encoding: "utf8" }));
  const stream = probe.streams?.[0];
  if (!stream) fail("ffprobe found no audio stream in " + path);
  const [num, den] = stream.time_base.split("/").map(Number);
  const frames = Number(stream.duration_ts);
  const sampleRate = Number(stream.sample_rate);
  if (!Number.isInteger(frames) || frames <= 0 || !Number.isFinite(sampleRate) || sampleRate <= 0) {
    fail("ffprobe returned invalid audio facts for " + path);
  }
  const samples = execFileSync("ffmpeg", [
    "-v", "error", "-i", path, "-map", "0:a:0", "-ac", "1", "-f", "f32le", "pipe:1"
  ], { maxBuffer: 64 * 1024 * 1024 });
  const pcm = new Float32Array(samples.buffer, samples.byteOffset, Math.floor(samples.byteLength / 4));
  if (pcm.length !== frames) {
    fail(path + " decoded " + pcm.length + " samples, ffprobe reports " + frames);
  }
  return { sampleRate, frames, duration: frames * num / den, pcm };
}

function lastAudibleFrame(pcm, start, end) {
  for (let index = end - 1; index >= start; index -= 1) {
    if (Math.abs(pcm[index]) > 0.003) return index;
  }
  return -1;
}

function factorOf(value, label) {
  const factor = value ?? { num: 1, den: 1 };
  if (!Number.isInteger(factor.num) || !Number.isInteger(factor.den) || factor.num <= 0 || factor.den <= 0) fail(label + " has an invalid retime factor");
  let a = factor.num;
  let b = factor.den;
  while (b !== 0) [a, b] = [b, a % b];
  return { num: factor.num / a, den: factor.den / a };
}

function sameFactor(left, right) {
  return left.num === right.num && left.den === right.den;
}

function validateTimedOccurrence(occurrence) {
  const factor = factorOf(occurrence.retimeFactor, "occurrence " + occurrence.id);
  const source = occurrence.sourceRange.duration;
  const output = occurrence.outputRange.duration;
  if (source.ticks * factor.den * output.timescale !== output.ticks * source.timescale * factor.num) {
    fail("occurrence " + occurrence.id + " output duration contradicts its retime factor");
  }
  return factor;
}

export function normalizeCtcText(text) {
  if (typeof text !== "string") fail("Transcript is not text");
  const parts = [];
  const symbols = [];
  const events = [];
  for (const match of text.matchAll(/\S+/gu)) {
    const lexeme = match[0];
    const location = match.index;
    const charStart = symbols.length;
    for (let offset = 0; offset < lexeme.length; offset += 1) {
      const character = lexeme[offset];
      if (/[A-Za-z]/.test(character) || character === "'") {
        symbols.push(character.toUpperCase());
      } else if (character === "-") {
        symbols.push("|");
        events.push({ position: location + offset, character, action: "hyphen to CTC separator; original lexeme retained" });
      } else if (".,!?;:\"()[]".includes(character)) {
        events.push({ position: location + offset, character, action: "punctuation omitted from acoustic target; original lexeme retained" });
      } else {
        fail("Unsupported transcript character " + JSON.stringify(character) + " at " + (location + offset) + "; no token dropped");
      }
    }
    if (symbols.length === charStart || !symbols.slice(charStart).some((symbol) => symbol !== "|")) {
      fail("Word has no supported acoustic symbols");
    }
    parts.push({ text: lexeme, location, length: lexeme.length, charStart, charEnd: symbols.length });
    symbols.push("|");
  }
  if (parts.length === 0) fail("Empty transcript");
  symbols.pop();
  return { parts, symbols, events };
}

function speechUtterancesFromScript(text) {
  const utterances = [];
  const pausePattern = /\[PAUSE:([0-9.]+)\]/g;
  let cursor = 0;
  let partIndex = 0;
  for (const match of text.matchAll(pausePattern)) {
    if (match.index > cursor) {
      const chunk = text.slice(cursor, match.index).trim();
      if (chunk.length > 0) {
        utterances.push({ id: "utterance-" + partIndex, text: chunk });
        partIndex += 1;
      }
    }
    partIndex += 1;
    cursor = match.index + match[0].length;
  }
  if (cursor < text.length) {
    const chunk = text.slice(cursor).trim();
    if (chunk.length > 0) utterances.push({ id: "utterance-" + partIndex, text: chunk });
  }
  return utterances;
}

function validateAudioReceipt(sourceId, receipt, facts) {
  if (receipt.origin !== "AVSpeechSynthesizer buffer write") fail(sourceId + " audio receipt has the wrong origin");
  if (receipt.sampleRate !== facts.sampleRate) fail(sourceId + " audio receipt sample rate disagrees with ffprobe");
  if (receipt.writtenFrames !== facts.frames || receipt.finalizedFrames !== facts.frames) {
    fail(sourceId + " audio receipt frame counts disagree with ffprobe");
  }
  close(receipt.durationSeconds, facts.duration, sourceId + " audio receipt duration");
}

function validateReceipt(sourceId, receipt, audioReceipt, facts, audioPath, textPath) {
  if (receipt.origin !== "torchaudio CTC known-text forced alignment") fail(sourceId + " receipt does not identify the CTC alignment route");
  if (receipt.isHumanGroundTruth !== false) fail(sourceId + " receipt claims human ground truth");
  const alignment = receipt.alignment;
  if (!alignment || alignment.engine !== "torchaudio WAV2VEC2_ASR_BASE_960H" || alignment.mode !== "known-text-forced" || alignment.threads !== 2 || typeof alignment.version !== "string" || alignment.modelSha256 !== PINNED_MODEL_SHA256 || !Array.isArray(alignment.acousticEvidence)) {
    fail(sourceId + " receipt lacks a concrete CTC aligner identity");
  }
  const inputAudio = receipt.inputAudio;
  if (!inputAudio || inputAudio.sha256 !== sha256(audioPath) || inputAudio.sampleRate !== facts.sampleRate || inputAudio.frames !== facts.frames) fail(sourceId + " receipt input audio does not match the generated file");
  const scriptText = readFileSync(textPath, "utf8");
  if (!receipt.inputText || receipt.inputText.sha256 !== sha256(textPath)) fail(sourceId + " receipt input text does not match its script");
  if (!Array.isArray(receipt.words) || receipt.words.length === 0 || receipt.wordCount !== receipt.words.length) fail(sourceId + " receipt has no complete word list");
  const scriptUtterances = speechUtterancesFromScript(scriptText);
  if (scriptUtterances.length !== audioReceipt.utterances.length || scriptUtterances.some((utterance, index) => utterance.id !== audioReceipt.utterances[index]?.id || utterance.text !== audioReceipt.utterances[index]?.text)) {
    fail(sourceId + " audio utterances do not match the input script");
  }
  const utterances = new Map(audioReceipt.utterances.map((utterance) => [utterance.id, utterance]));
  if (utterances.size !== audioReceipt.utterances.length) fail(sourceId + " audio receipt utterance ids are not unique");
  const evidenceByUtterance = new Map();
  for (const evidence of alignment.acousticEvidence) {
    if (!evidence || typeof evidence.utteranceId !== "string" || evidenceByUtterance.has(evidence.utteranceId)) fail(sourceId + " acoustic evidence does not identify each utterance exactly once");
    const utterance = utterances.get(evidence.utteranceId);
    if (!utterance || evidence.sourceStartFrame !== utterance.startFrame || evidence.sourceEndFrame !== utterance.endFrame || evidence.sourceSampleRate !== facts.sampleRate || !Number.isInteger(evidence.emissionFrames) || evidence.emissionFrames <= 0 || !Number.isFinite(evidence.secondsPerEmissionFrame) || evidence.secondsPerEmissionFrame <= 0 || !Array.isArray(evidence.ctcTokens)) {
      fail(sourceId + " acoustic evidence disagrees with its utterance origin");
    }
    close(evidence.secondsPerEmissionFrame, (utterance.endFrame - utterance.startFrame) / facts.sampleRate / evidence.emissionFrames, sourceId + " acoustic evidence frame clock");
    const normalized = normalizeCtcText(utterance.text);
    const expectedSymbols = normalized.symbols;
    if (evidence.normalizedTranscript !== expectedSymbols.join("")) {
      fail(sourceId + " normalized transcript differs from its utterance origin");
    }
    if (evidence.ctcTokens.length !== expectedSymbols.length) {
      fail(sourceId + " retained CTC rows do not cover the normalized transcript");
    }
    let previousTokenEnd = 0;
    for (const token of evidence.ctcTokens) {
      if (!Number.isInteger(token.token) || !Number.isInteger(token.startEmissionFrame) || !Number.isInteger(token.endEmissionFrame) || token.startEmissionFrame < 0 || token.startEmissionFrame >= token.endEmissionFrame || token.endEmissionFrame > evidence.emissionFrames || !Number.isFinite(token.meanProbability) || token.meanProbability < 0 || token.meanProbability > 1) {
        fail(sourceId + " acoustic evidence has invalid retained CTC rows");
      }
      if (token.startEmissionFrame < previousTokenEnd) {
        fail(sourceId + " retained CTC rows are not chronological and non-overlapping");
      }
      previousTokenEnd = token.endEmissionFrame;
    }
    for (const [tokenIndex, token] of evidence.ctcTokens.entries()) {
      if (token.token < 0 || token.token >= WAV2VEC2_ASR_BASE_960H_LABELS.length || WAV2VEC2_ASR_BASE_960H_LABELS[token.token] !== token.symbol) {
        fail(sourceId + " retained CTC token does not match the pinned label dictionary");
      }
      if (token.symbol !== expectedSymbols[tokenIndex]) {
        fail(sourceId + " retained CTC symbols differ from the normalized transcript");
      }
    }
    evidenceByUtterance.set(evidence.utteranceId, { ...evidence, normalized });
  }
  if (evidenceByUtterance.size !== utterances.size) fail(sourceId + " acoustic evidence does not identify each utterance exactly once");
  const expectedWords = audioReceipt.utterances.flatMap((utterance) => {
    const evidence = evidenceByUtterance.get(utterance.id);
    return evidence.normalized.parts.map((part) => ({ ...part, utteranceId: utterance.id }));
  });
  if (expectedWords.length !== receipt.words.length) fail(sourceId + " receipt does not preserve one-to-one transcript coverage");
  const ids = new Set();
  let previousEnd = 0;
  for (const [index, word] of receipt.words.entries()) {
    if (typeof word.id !== "string" || word.id.length === 0 || ids.has(word.id)) fail(sourceId + " word ids are not unique");
    ids.add(word.id);
    const expectedWord = expectedWords[index];
    if (word.utteranceId !== expectedWord.utteranceId || word.text !== expectedWord.text) fail(sourceId + " word text differs from its transcript origin");
    const start = word.sourceStartSeconds;
    const end = word.sourceEndSeconds;
    const rawStart = word.rawStartSeconds;
    const rawEnd = word.rawEndSeconds;
    const utterance = utterances.get(word.utteranceId);
    if (!utterance) fail(sourceId + " word has an unknown utterance origin");
    const evidence = evidenceByUtterance.get(word.utteranceId);
    const characterRange = word.characterRange;
    if (!Number.isInteger(characterRange?.location) || !Number.isInteger(characterRange?.length) || characterRange.location !== expectedWord.location || characterRange.length !== expectedWord.length || utterance.text.slice(characterRange.location, characterRange.location + characterRange.length) !== word.text) {
      fail(sourceId + " word character range does not select its original lexeme");
    }
    if (!Number.isFinite(start) || !Number.isFinite(end) || !Number.isFinite(rawStart) || !Number.isFinite(rawEnd) || start < 0 || end <= start || end > facts.duration + EPSILON) fail(sourceId + " word has non-finite or invalid timing");
    close(start, rawStart, sourceId + " raw CTC start");
    close(end, rawEnd, sourceId + " raw CTC end");
    if (start < utterance.startFrame / facts.sampleRate || end > utterance.endFrame / facts.sampleRate || start < previousEnd) fail(sourceId + " word crosses its utterance origin or overlaps");
    if (!Array.isArray(word.tokens) || word.tokens.length === 0 || !Number.isInteger(word.ctcEmissionStart) || !Number.isInteger(word.ctcEmissionEnd) || word.ctcEmissionStart < 0 || word.ctcEmissionStart >= word.ctcEmissionEnd || word.ctcEmissionEnd > evidence.emissionFrames) fail(sourceId + " word lacks CTC token evidence");
    const tokenRows = evidence.ctcTokens.slice(expectedWord.charStart, expectedWord.charEnd);
    if (tokenRows.length === 0 || JSON.stringify(tokenRows.map((token) => token.token)) !== JSON.stringify(word.tokens)) fail(sourceId + " word tokens do not match retained CTC rows");
    if (word.ctcEmissionStart !== tokenRows[0].startEmissionFrame || word.ctcEmissionEnd !== tokenRows.at(-1).endEmissionFrame) {
      fail(sourceId + " word emission endpoints do not match its normalized token rows");
    }
    const tokenFrames = tokenRows.reduce((total, token) => total + token.endEmissionFrame - token.startEmissionFrame, 0);
    const weightedProbability = tokenRows.reduce((total, token) => total + token.meanProbability * (token.endEmissionFrame - token.startEmissionFrame), 0) / tokenFrames;
    if (!Number.isFinite(word.probability) || word.probability < 0 || word.probability > 1 || Math.abs(word.probability - weightedProbability) > PROBABILITY_EPSILON) fail(sourceId + " word probability does not match retained CTC rows");
    close(rawStart, utterance.startFrame / facts.sampleRate + word.ctcEmissionStart * evidence.secondsPerEmissionFrame, sourceId + " raw CTC emission start");
    close(rawEnd, utterance.startFrame / facts.sampleRate + word.ctcEmissionEnd * evidence.secondsPerEmissionFrame, sourceId + " raw CTC emission end");
    const startFrame = Math.round(start * facts.sampleRate);
    const endFrame = Math.round(end * facts.sampleRate);
    const tail = word.acousticTailEndFrame;
    const nextWord = receipt.words[index + 1];
    const nextOnset = nextWord?.utteranceId === word.utteranceId ? Math.round(nextWord.sourceStartSeconds * facts.sampleRate) : utterance.endFrame;
    const tailCap = Math.min(utterance.endFrame, nextOnset);
    if (!Number.isInteger(tail) || tail < startFrame || tail > tailCap || !Number.isFinite(word.acousticTailEndSeconds)) fail(sourceId + " word has an invalid acoustic-tail estimate");
    close(word.acousticTailEndSeconds, tail / facts.sampleRate, sourceId + " acoustic tail seconds");
    const audible = lastAudibleFrame(facts.pcm, startFrame, Math.min(tail, utterance.endFrame));
    if (audible < startFrame) fail(sourceId + " word has no active waveform support");
    previousEnd = end;
  }
}

function projected(source, cut, sourceRange) {
  const sourceCut = rangeOf(cut.sourceRange);
  const outputCut = rangeOf(cut.outputRange);
  if (cut.takeSourceId !== source || !contains(sourceCut, sourceRange)) {
    fail("source range does not belong to occurrence " + cut.occurrenceId);
  }
  const factor = cut.retimeFactor ? cut.retimeFactor.num / cut.retimeFactor.den : 1;
  return {
    start: outputCut.start + (sourceRange.start - sourceCut.start) / factor,
    end: outputCut.start + (sourceRange.end - sourceCut.start) / factor
  };
}

function validateManifest(manifest, receipts, factsBySource, audioReceipts, paths) {
  const plan = manifest.canonicalPlan;
  const cuts = new Map(plan.cutList.map((cut) => [cut.occurrenceId, cut]));
  const mappings = new Map(manifest.expected.sourceToOutput.map((mapping) => [mapping.occurrenceId, mapping]));
  if (mappings.size !== plan.occurrences.length) fail("source-to-output mappings must identify every occurrence exactly once");
  for (const occurrence of plan.occurrences) {
    const occurrenceFactor = validateTimedOccurrence(occurrence);
    const mapping = mappings.get(occurrence.id);
    if (!mapping || mapping.sourceId !== occurrence.sourceId || JSON.stringify(mapping.sourceRange) !== JSON.stringify(occurrence.sourceRange) || JSON.stringify(mapping.outputRange) !== JSON.stringify(occurrence.outputRange)) {
      fail("source-to-output mapping does not preserve occurrence " + occurrence.id);
    }
    if (occurrence.role === "dialogue") {
      const cut = cuts.get(occurrence.id);
      if (!cut || !sameFactor(occurrenceFactor, factorOf(cut.retimeFactor, "cut " + occurrence.id))) fail("cut list retime factor does not preserve occurrence " + occurrence.id);
    }
  }
  const dialogue = new Map(plan.occurrences.filter((occurrence) => occurrence.role === "dialogue").map((occurrence) => [occurrence.id, occurrence]));
  if (cuts.size !== dialogue.size) fail("cut list must identify every dialogue occurrence exactly once");
  for (const [id, occurrence] of dialogue) {
    const cut = cuts.get(id);
    if (!cut || cut.takeSourceId !== occurrence.sourceId || JSON.stringify(cut.sourceRange) !== JSON.stringify(occurrence.sourceRange) || JSON.stringify(cut.outputRange) !== JSON.stringify(occurrence.outputRange)) {
      fail("cut list does not preserve occurrence " + id);
    }
  }
  for (const [sourceId, receipt] of Object.entries(receipts)) {
    validateAudioReceipt(sourceId, audioReceipts[sourceId], factsBySource[sourceId]);
    validateReceipt(sourceId, receipt, audioReceipts[sourceId], factsBySource[sourceId], paths.audio[sourceId], paths.text[sourceId]);
  }

  const wordsBySource = Object.fromEntries(Object.entries(receipts).map(([id, receipt]) => [id, new Map(receipt.words.map((word) => [word.id, word]))]));
  const correctionApplications = new Map();
  for (const correction of plan.wordCorrections) {
    const word = wordsBySource[correction.sourceId]?.get(correction.wordId);
    if (!word || word.text !== correction.fromText || correction.timingUnchanged !== true) {
      fail("correction does not identify its source word");
    }
    if (!Array.isArray(correction.occurrenceIds) || correction.occurrenceIds.length === 0 || new Set(correction.occurrenceIds).size !== correction.occurrenceIds.length) fail("correction does not select a unique occurrence");
    const sourceRange = { start: word.sourceStartSeconds, end: word.sourceEndSeconds };
    for (const occurrenceId of correction.occurrenceIds) {
      const cut = cuts.get(occurrenceId);
      if (!cut) fail("correction selects an unknown occurrence");
      const key = correction.sourceId + "/" + correction.wordId + "/" + occurrenceId;
      correctionApplications.set(key, 0);
    }
  }
  for (const caption of manifest.expected.captions) {
    const cut = cuts.get(caption.occurrenceId);
    if (!cut || caption.takeSourceId !== cut.takeSourceId || caption.straddlesCut !== false) {
      fail("caption does not name one cut occurrence");
    }
    const sourceRange = rangeOf(caption.sourceRange);
    const outputRange = rangeOf(caption.outputRange);
    const mapped = projected(caption.takeSourceId, cut, sourceRange);
    close(outputRange.start, mapped.start, "caption output start");
    close(outputRange.end, mapped.end, "caption output end");
    const sourceWords = receipts[caption.takeSourceId].words.filter((word) => contains(sourceRange, { start: word.sourceStartSeconds, end: word.sourceEndSeconds }));
    if (sourceWords.length === 0) fail("caption has no source words");
    const replacements = new Map();
    for (const correction of plan.wordCorrections) {
      if (correction.sourceId !== caption.takeSourceId || !correction.occurrenceIds.includes(caption.occurrenceId)) continue;
      const selected = wordsBySource[correction.sourceId].get(correction.wordId);
      if (contains(sourceRange, { start: selected.sourceStartSeconds, end: selected.sourceEndSeconds })) {
        replacements.set(correction.wordId, correction.toText);
        const key = correction.sourceId + "/" + correction.wordId + "/" + caption.occurrenceId;
        correctionApplications.set(key, (correctionApplications.get(key) ?? 0) + 1);
      }
    }
    const reconstructed = sourceWords.map((word) => replacements.get(word.id) ?? word.text).join(" ");
    if (caption.text !== reconstructed) fail("caption text does not reconstruct from its source words");
  }
  for (const [key, applications] of correctionApplications) {
    if (applications !== 1) fail("correction must apply exactly once in selected output captions: " + key);
  }
}

export function validateTFixture(dir) {
  const manifest = readJson(join(dir, "manifest.json"));
  const receipts = {
    take1: readJson(join(dir, "words-take1.json")),
    take2: readJson(join(dir, "words-take2.json"))
  };
  const factsBySource = {
    take1: audioFacts(join(dir, "media/take1-speech.aiff")),
    take2: audioFacts(join(dir, "media/take2-speech.aiff"))
  };
  const audioReceipts = {
    take1: readJson(join(dir, "audio-take1.json")),
    take2: readJson(join(dir, "audio-take2.json"))
  };
  const paths = {
    audio: { take1: join(dir, "media/take1-speech.aiff"), take2: join(dir, "media/take2-speech.aiff") },
    text: { take1: join(dir, "script-take1.txt"), take2: join(dir, "script-take2.txt") }
  };
  validateManifest(manifest, receipts, factsBySource, audioReceipts, paths);
  return { take1Frames: factsBySource.take1.frames, take2Frames: factsBySource.take2.frames };
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const dir = process.argv[2];
  if (!dir) fail("usage: verify-t-contract.mjs <T fixture dir>");
  const facts = validateTFixture(dir);
  console.log("ok T audio frames take1=" + facts.take1Frames + " take2=" + facts.take2Frames);
}
