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
const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));

function norm(s) {
  return String(s).toLowerCase().replace(/[^a-z]/g, "");
}

function findIndex(words, text) {
  const n = norm(text);
  const i = words.findIndex((w) => norm(w.text) === n);
  if (i < 0) throw new Error("word not found: " + text);
  return i;
}

function phrase(words, startText, endText, after = 0) {
  const start = words.findIndex(
    (w) => w.sourceStartSeconds + 1e-9 >= after && norm(w.text) === norm(startText)
  );
  if (start < 0) throw new Error("word not found after " + after + ": " + startText);
  let end = -1;
  for (let i = start; i < words.length; i++) {
    if (norm(words[i].text) === norm(endText)) {
      end = i;
      break;
    }
  }
  if (end < 0) throw new Error("phrase end not found: " + endText);
  const slice = words.slice(start, end + 1);
  return {
    text: slice.map((w) => w.text).join(" "),
    start: slice[0].sourceStartSeconds,
    end: slice[slice.length - 1].sourceEndSeconds
  };
}

function asRational(seconds, timescale = 1000) {
  return {
    ticks: Math.round(seconds * timescale),
    timescale
  };
}

function secondsOf(r) {
  return r.ticks / r.timescale;
}

function mapThroughCuts(takeId, sourceStart, sourceEnd, cuts) {
  for (const cut of cuts) {
    if (cut.takeSourceId !== takeId) continue;
    const cs = secondsOf(cut.sourceRange.start);
    const cd = secondsOf(cut.sourceRange.duration);
    const ce = cs + cd;
    if (sourceStart + 1e-6 < cs || sourceEnd - 1e-6 > ce) continue;
    const os = secondsOf(cut.outputRange.start);
    const retime = cut.retimeFactor ? cut.retimeFactor.num / cut.retimeFactor.den : 1;
    return {
      start: os + (sourceStart - cs) / retime,
      duration: (sourceEnd - sourceStart) / retime
    };
  }
  throw new Error("no cut contains " + takeId + " " + sourceStart + "-" + sourceEnd);
}

const w1 = take1.words;
const w2 = take2.words;
const cuts = manifest.canonicalPlan.cutList;

manifest.canonicalPlan.wordCorrections = [
  { wordIndex: findIndex(w1, "operator"), fromText: "operator", toText: "creator", timingUnchanged: true },
  { wordIndex: findIndex(w1, "false"), fromText: "false", toText: "wrong", timingUnchanged: true },
  { wordIndex: findIndex(w1, "owns"), fromText: "owns", toText: "keeps", timingUnchanged: true },
  { wordIndex: findIndex(w1, "bed"), fromText: "bed", toText: "track", timingUnchanged: true },
  { wordIndex: findIndex(w1, "share"), fromText: w1[findIndex(w1, "share")].text, toText: "keep", timingUnchanged: true }
];

const captions = [
  { take: "take1", words: w1, startText: "Hold", endText: "thought", after: 0 },
  { take: "take2", words: w2, startText: "operator", endText: "cut", after: 10 },
  { take: "take1", words: w1, startText: "same", endText: "share", after: 36 },
  { take: "take2", words: w2, startText: "Chapter", endText: "segment", after: 10 }
];

manifest.expected.captions = captions.map((c) => {
  const p = phrase(c.words, c.startText, c.endText, c.after ?? 0);
  const mapped = mapThroughCuts(c.take, p.start, p.end, cuts);
  return {
    text: p.text,
    sourceRange: {
      start: asRational(p.start),
      duration: asRational(p.end - p.start)
    },
    outputRange: {
      start: asRational(mapped.start),
      duration: asRational(mapped.duration)
    },
    takeSourceId: c.take,
    straddlesCut: false
  };
});

writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log("stamped T captions and word corrections");
