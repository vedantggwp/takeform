#!/usr/bin/env node
"use strict";

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const EPSILON = 0.0011;
const PROBABILITY_EPSILON = 1e-9;
const PINNED_MODEL_SHA256 = "488fd4f16de84438ffc945334278c1b9fb9b7159a806c1080b16111a958c945d";

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

function normalizedWord(text) {
  return String(text).toLowerCase().replace(/[^a-z]/g, "");
}

function tokenRowsForWord(evidence, word) {
  return evidence.ctcTokens.filter((token) =>
    token.startEmissionFrame >= word.ctcEmissionStart && token.endEmissionFrame <= word.ctcEmissionEnd
  );
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
  if (!receipt.inputText || receipt.inputText.sha256 !== sha256(textPath)) fail(sourceId + " receipt input text does not match its script");
  if (!Array.isArray(receipt.words) || receipt.words.length === 0 || receipt.wordCount !== receipt.words.length) fail(sourceId + " receipt has no complete word list");
  const utterances = new Map(audioReceipt.utterances.map((utterance) => [utterance.id, utterance]));
  const evidenceByUtterance = new Map();
  for (const evidence of alignment.acousticEvidence) {
    if (!evidence || typeof evidence.utteranceId !== "string" || evidenceByUtterance.has(evidence.utteranceId)) fail(sourceId + " acoustic evidence does not identify each utterance exactly once");
    const utterance = utterances.get(evidence.utteranceId);
    if (!utterance || evidence.sourceStartFrame !== utterance.startFrame || evidence.sourceEndFrame !== utterance.endFrame || evidence.sourceSampleRate !== facts.sampleRate || !Number.isInteger(evidence.emissionFrames) || evidence.emissionFrames <= 0 || !Number.isFinite(evidence.secondsPerEmissionFrame) || evidence.secondsPerEmissionFrame <= 0 || !Array.isArray(evidence.ctcTokens)) {
      fail(sourceId + " acoustic evidence disagrees with its utterance origin");
    }
    close(evidence.secondsPerEmissionFrame, (utterance.endFrame - utterance.startFrame) / facts.sampleRate / evidence.emissionFrames, sourceId + " acoustic evidence frame clock");
    for (const token of evidence.ctcTokens) {
      if (!Number.isInteger(token.token) || !Number.isInteger(token.startEmissionFrame) || !Number.isInteger(token.endEmissionFrame) || token.startEmissionFrame < 0 || token.startEmissionFrame >= token.endEmissionFrame || token.endEmissionFrame > evidence.emissionFrames || !Number.isFinite(token.meanProbability) || token.meanProbability < 0 || token.meanProbability > 1) {
        fail(sourceId + " acoustic evidence has invalid retained CTC rows");
      }
    }
    evidenceByUtterance.set(evidence.utteranceId, evidence);
  }
  if (evidenceByUtterance.size !== utterances.size) fail(sourceId + " acoustic evidence does not identify each utterance exactly once");
  const expected = audioReceipt.utterances.flatMap((utterance) => utterance.text.split(/\s+/).filter(Boolean));
  if (expected.length !== receipt.words.length) fail(sourceId + " receipt does not preserve one-to-one transcript coverage");
  const ids = new Set();
  let previousEnd = 0;
  for (const [index, word] of receipt.words.entries()) {
    if (typeof word.id !== "string" || word.id.length === 0 || ids.has(word.id)) fail(sourceId + " word ids are not unique");
    ids.add(word.id);
    if (normalizedWord(word.text) !== normalizedWord(expected[index])) fail(sourceId + " word text differs from its transcript origin");
    const start = word.sourceStartSeconds;
    const end = word.sourceEndSeconds;
    const rawStart = word.rawStartSeconds;
    const rawEnd = word.rawEndSeconds;
    const utterance = utterances.get(word.utteranceId);
    if (!utterance) fail(sourceId + " word has an unknown utterance origin");
    const evidence = evidenceByUtterance.get(word.utteranceId);
    const characterRange = word.characterRange;
    if (!Number.isInteger(characterRange?.location) || !Number.isInteger(characterRange?.length) || characterRange.location < 0 || characterRange.length <= 0 || utterance.text.slice(characterRange.location, characterRange.location + characterRange.length) !== word.text) {
      fail(sourceId + " word character range does not select its original lexeme");
    }
    if (!Number.isFinite(start) || !Number.isFinite(end) || !Number.isFinite(rawStart) || !Number.isFinite(rawEnd) || start < 0 || end <= start || end > facts.duration + EPSILON) fail(sourceId + " word has non-finite or invalid timing");
    close(start, rawStart, sourceId + " raw CTC start");
    close(end, rawEnd, sourceId + " raw CTC end");
    if (start < utterance.startFrame / facts.sampleRate || end > utterance.endFrame / facts.sampleRate || start < previousEnd) fail(sourceId + " word crosses its utterance origin or overlaps");
    if (!Array.isArray(word.tokens) || word.tokens.length === 0 || !Number.isInteger(word.ctcEmissionStart) || !Number.isInteger(word.ctcEmissionEnd) || word.ctcEmissionStart < 0 || word.ctcEmissionStart >= word.ctcEmissionEnd || word.ctcEmissionEnd > evidence.emissionFrames) fail(sourceId + " word lacks CTC token evidence");
    const tokenRows = tokenRowsForWord(evidence, word);
    if (tokenRows.length === 0 || JSON.stringify(tokenRows.map((token) => token.token)) !== JSON.stringify(word.tokens)) fail(sourceId + " word tokens do not match retained CTC rows");
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
